import AVFoundation
import AppKit
import Foundation
import Speech
@testable import AtomVoiceCore

/// 仅显式网络 probe 调用；make test 的离线入口不会执行网络或读取真实密钥。
enum OpenAILiveProbe {
    /// 显式模型目录验收：不进入音频预算、Speech 或窗口路径。
    static func runModels() async -> Never {
        do {
            let key: String
            switch AppSettings.openaiASR.apiKeyReadResult() {
            case .value(let value):
                key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw OpenAIASRSettingsError.missingKey }
            case .notFound: throw OpenAIASRSettingsError.missingKey
            case .failure: throw OpenAIASRSettingsError.keychainUnavailable
            }
            let models = try await OpenAIASRModelCatalog().fetch(apiKey: key)
            // Catalog 已筛选客户端支持的公共别名，绝不输出原始 /models 响应。
            printReport(["mode": "models_catalog", "models": models.map(\.rawValue),
                         "count": models.count, "passed": true])
            exit(0)
        } catch let error as OpenAIASRSettingsError {
            let code: String
            switch error {
            case .missingKey: code = "missing_key"
            case .keychainUnavailable: code = "keychain_unavailable"
            case .invalidConfiguration: code = "invalid_configuration"
            }
            printReport(["mode": "models_catalog", "passed": false, "error_code": code])
            exit(2)
        } catch let error as CloudASRFailure {
            printReport(["mode": "models_catalog", "passed": false,
                         "error_code": String(describing: error.kind), "error": error.message])
            exit(1)
        } catch {
            printReport(["mode": "models_catalog", "passed": false, "error_code": "catalog_failed"])
            exit(2)
        }
    }

    @MainActor
    static func run(_ arguments: [String]) async -> Never {
        do {
            guard let index = arguments.firstIndex(of: "--openai-live-probe"), arguments.count > index + 1 else {
                throw ProbeError.arguments
            }
            let modelOverride = try requestedModel(in: arguments)
            let url = URL(fileURLWithPath: arguments[index + 1])
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let paced = arguments.contains("--paced")
            let expectedTail = argumentValue("--expect-tail", in: arguments)
            let ledgerPath = arguments.firstIndex(of: "--cost-ledger").flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            try reserveCost(seconds: duration, path: ledgerPath)
            if arguments.contains("--controller") {
                let report = try await runController(file: file, duration: duration, arguments: arguments,
                                                     modelOverride: modelOverride)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(report["passed"] as? Bool == true ? 0 : 1)
            }
            let original = try AppSettings.openaiASR.snapshot(selectedLanguage: arguments.contains("--english") ? "en-US" : "zh-CN")
            var configuration = original.configuration
            if let modelOverride { configuration.model = modelOverride }
            if let delay = arguments.first(where: { $0.hasPrefix("--delay=") }) {
                configuration.delay = String(delay.dropFirst("--delay=".count))
            }
            let snapshot = OpenAIASRRuntimeSettings(apiKey: original.apiKey, configuration: try configuration.validated())
            let provider = OpenAITranscriptionProvider(snapshot: { snapshot })
            let recognizer = CloudASRRecognizerController(provider: provider)
            let started = ProcessInfo.processInfo.systemUptime
            var firstDelta: Double?
            var finalSeen = false
            var partialEvents = 0
            var lastCount = 0
            var failure: String?
            let startError = recognizer.start(onResult: { text, final in
                if !final, !text.isEmpty {
                    if firstDelta == nil { firstDelta = ProcessInfo.processInfo.systemUptime }
                    partialEvents += 1
                }
                lastCount = text.count
                finalSeen = finalSeen || final
            }, onError: { error in failure = error.message })
            guard startError == nil else { throw ProbeError.start }
            let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
            while file.framePosition < file.length, failure == nil {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                    throw ProbeError.audio
                }
                try file.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                recognizer.accept(buffer: buffer)
                try await Task.sleep(nanoseconds: paced ? 100_000_000 : 2_000_000)
            }
            let stopped = ProcessInfo.processInfo.systemUptime
            var completed = false
            var resultAt: Double?
            var resultCount = 0
            var resultError: String?
            var tailMatches = expectedTail == nil
            recognizer.stop { text, error in
                resultCount = text.count
                resultError = error
                resultAt = ProcessInfo.processInfo.systemUptime
                tailMatches = expectedTail.map { normalized(text).hasSuffix(normalized($0)) } ?? true
                completed = true
            }
            let deadline = stopped + 25
            while !completed, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            recognizer.cancel()
            var report: [String: Any] = [
                "mode": "production_cloud", "audio_seconds": duration,
                "model": snapshot.configuration.resolvedModel.rawValue,
                "model_confirmed": finalSeen && failure == nil && resultError == nil,
                "delay": snapshot.configuration.delay ?? "server_default",
                "paced": paced, "completed": completed, "confirmed_final": finalSeen,
                "partial_events": partialEvents, "result_characters": resultCount,
                "pre_stop_partial": firstDelta.map { $0 < stopped } ?? false,
                "latest_characters": lastCount,
                "stop_to_result_ms": resultAt.map { ($0 - stopped) * 1000 } ?? -1,
                "total_seconds": ProcessInfo.processInfo.systemUptime - started,
                "had_error": failure != nil || resultError != nil,
                "tail_checked": expectedTail != nil, "tail_matches": tailMatches,
            ]
            if let firstDelta { report["first_delta_ms"] = (firstDelta - started) * 1000 }
            // 服务端错误已由生产codec映射为固定本地化文案，不保存识别原文。
            report["error"] = failure ?? resultError
            let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: output, as: UTF8.self))
            let streamingPassed = !paced || firstDelta.map { $0 < stopped } == true
            exit(completed && finalSeen && resultCount > 0 && failure == nil && resultError == nil && streamingPassed && tailMatches ? 0 : 1)
        } catch ProbeError.arguments {
            print("{\"probe_failed\":true,\"error_code\":\"arguments\"}")
            exit(2)
        } catch {
            print("{\"probe_failed\":true,\"error_type\":\"\(String(describing: type(of: error)))\"}")
            exit(2)
        }
    }

    private enum ProbeError: Error { case arguments, audio, start, budget }

    private static func requestedModel(in arguments: [String]) throws -> OpenAIASRModel? {
        guard !arguments.contains("--model") else { throw ProbeError.arguments }
        let values = arguments.filter { $0.hasPrefix("--model=") }
        guard values.count <= 1 else { throw ProbeError.arguments }
        guard let value = values.first else { return nil }
        guard let model = OpenAIASRModel(rawValue: String(value.dropFirst("--model=".count))) else {
            throw ProbeError.arguments
        }
        return model
    }

    private static func printReport(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            print("{\"probe_failed\":true,\"error_code\":\"report_encoding\"}")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    fileprivate static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    @MainActor
    private static func runController(file: AVAudioFile, duration: Double, arguments: [String],
                                      modelOverride: OpenAIASRModel?) async throws -> [String: Any] {
        // 使用进程内参数域覆盖测试选项；即使测试进程崩溃，也不改用户的持久设置。
        let defaults = UserDefaults.standard
        let savedDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var testDomain = savedDomain
        var configuration = try AppSettings.openaiASR.configuration()
        if let modelOverride { configuration.model = modelOverride }
        configuration = try configuration.validated()
        testDomain[AppSettings.Keys.openaiASRConfiguration] = try JSONEncoder().encode(configuration)
        testDomain[AppSettings.Keys.recognitionEngine] = OpenAIASRSettings.engineCode
        testDomain[AppSettings.Keys.selectedLanguage] = arguments.contains("--english") ? "en-US" : "zh-CN"
        testDomain[AppSettings.Keys.llmEnabled] = false
        testDomain[AppSettings.Keys.silenceAutoStopEnabled] = false
        testDomain[AppSettings.Keys.lowerVolumeOnRecording] = false
        testDomain[AppSettings.Keys.openaiASRPrivacyAccepted] = true
        testDomain[AppSettings.Keys.textOutputSink] = "openai-probe"
        defaults.setVolatileDomain(testDomain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(savedDomain, forName: UserDefaults.argumentDomain) }

        var captureAt: Double?
        var captureCount = 0
        let audio = AudioEngineController(startOperationOverride: {
            if captureAt == nil { captureAt = ProcessInfo.processInfo.systemUptime }
            captureCount += 1
            return true
        }, stopOperationOverride: {})
        let presenter = ProbePresenter()
        let output = ProbeSink(useWindow: arguments.contains("--window"), expectedTail: argumentValue("--expect-tail", in: arguments))
        if arguments.contains("--authorize-speech"), SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        let provider: any ASREngineProviding
        let base = ASREngineProvider()
        let apple = ProbeSpeechObserver(base.speechRecognizer())
        var faultProvider: ProbeFaultProvider?
        let fault = arguments.first { $0.hasPrefix("--fault=") }.map { String($0.dropFirst("--fault=".count)) }
        if let fault {
            let injection = ProbeFaultProvider(mode: fault)
            faultProvider = injection
            let cloud = CloudASREngine(provider: injection, descriptor: .openAI)
            let session = CloudRecognitionSession(cloudEngine: cloud, appleEngine: AppleSpeechASREngine(recognizer: apple),
                speechRecognizerProvider: { apple }, audioEngine: audio,
                privacyAccepted: { true }, privacyErrorKey: "openai.error.privacyNotAccepted",
                fallbackErrorKey: "openai.fallback.withError", validatesCredentialsDuringPreflight: false)
            provider = ProbeSessionProvider(base: base, session: session)
        } else { provider = base }
        let controller = RecordingSessionController(audioEngine: audio, presenter: presenter,
            llmRefiner: LLMRefiner(), textPostProcessorRegistry: TextPostProcessorRegistry(processors: []),
            textOutputSinkRegistry: TextOutputSinkRegistry(sinks: [output], fallbackCode: output.descriptor.code),
            volumeController: VolumeController(), asrEngineRegistry: ASREngineRegistry.shared, asrEngineProvider: provider)
        defer { controller.cancel(); output.close() }
        let began = ProcessInfo.processInfo.systemUptime
        controller.start()
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        var firstFrameAt: Double?
        var didRestart = false
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw ProbeError.audio
            }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            if firstFrameAt == nil { firstFrameAt = ProcessInfo.processInfo.systemUptime }
            audio.router.receive(buffer)
            try await Task.sleep(nanoseconds: arguments.contains("--paced") ? 100_000_000 : 2_000_000)
            if arguments.contains("--cancel-restart"), !didRestart, file.framePosition >= AVAudioFramePosition(file.processingFormat.sampleRate) {
                didRestart = true
                controller.cancel()
                presenter.firstTextAt = nil
                file.framePosition = 0
                controller.start()
            }
        }
        let stopped = ProcessInfo.processInfo.systemUptime
        if arguments.contains("--cancel") { controller.cancel() }
        else if arguments.contains("--immediate") { controller.stopImmediate(appending: nil) }
        else { controller.stop() }
        let cancelled = arguments.contains("--cancel")
        let deadline = stopped + (cancelled ? 2 : 35)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !cancelled, output.completionCount > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let triggerAt = faultProvider?.triggeredAt
        let faultTimingPassed = triggerAt.map { fault == "final" ? $0 >= stopped : $0 < stopped } ?? false
        let enginePassed = fault == nil ? controller.currentRecordingEngine == OpenAIASRSettings.engineCode :
            controller.currentRecordingEngine == ASREngineRegistry.appleCode && faultTimingPassed
        let preStopPartial = presenter.firstTextAt.map { $0 < stopped } ?? false
        let streamingPassed = !arguments.contains("--paced") || fault != nil || preStopPartial
        let applePassed = fault == nil || apple.recognizedCharacters > 0
        var report: [String: Any] = ["mode": "production_controller",
            "model": configuration.resolvedModel.rawValue,
            "model_confirmed": !cancelled && !arguments.contains("--immediate") && fault == nil &&
                controller.currentRecordingEngine == OpenAIASRSettings.engineCode &&
                output.deliveryCount == 1 && output.completionCount == 1 && output.characters > 0,
            "audio_seconds": duration, "paced": arguments.contains("--paced"),
            "deliveries": output.deliveryCount, "characters": output.characters,
            "window_used": arguments.contains("--window"),
            "window_received": output.windowReceived, "cancelled": cancelled,
            "capture_count": captureCount, "restarted": didRestart,
            "tail_checked": output.expectedTail != nil, "tail_matches": output.tailMatches,
            "fault": fault ?? "none",
            "fault_triggered": triggerAt != nil,
            "early_cloud_failure": faultProvider?.earlyFailure ?? "none",
            "fault_timing_passed": faultTimingPassed,
            "apple_characters": apple.recognizedCharacters,
            "apple_cached_characters": apple.cachedCharacters,
            "apple_cached_audio_seconds": apple.cachedAudioSeconds,
            "apple_cached_frames": apple.cachedFrames,
            "apple_cached_final": apple.cachedFinalSeen,
            "pre_stop_partial": preStopPartial,
            "effective_engine": controller.currentRecordingEngine,
            "speech_permission": SFSpeechRecognizer.authorizationStatus().rawValue,
            "stop_to_delivery_ms": output.deliveredAt.map { ($0 - stopped) * 1000 } ?? -1,
            "passed": cancelled ? output.deliveryCount == 0 : output.deliveryCount == 1 && output.completionCount == 1 &&
                output.characters > 0 && output.windowReceived && enginePassed && streamingPassed && applePassed && output.tailMatches &&
                (!arguments.contains("--cancel-restart") || didRestart && captureCount == 2)]
        if let captureAt { report["capture_start_ms"] = (captureAt - began) * 1000 }
        if let firstFrameAt { report["first_frame_ms"] = (firstFrameAt - began) * 1000 }
        if let first = presenter.firstTextAt { report["first_text_ms"] = (first - began) * 1000 }
        report["errors"] = presenter.errorCount
        return report
    }

    private static func reserveCost(seconds: Double, path: String?) throws {
        let url = path.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".codex/private/openai-integration/test-cost-reservations.json")
        var ledger = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Double]
        } ?? [:]
        let reserve = max(0.05, seconds / 60 * 0.017 * 2)
        let next = (ledger["reserved_usd"] ?? 0) + reserve
        guard next <= 10 else { throw ProbeError.budget }
        ledger["reserved_usd"] = next
        ledger["audio_seconds"] = (ledger["audio_seconds"] ?? 0) + seconds
        ledger["runs"] = (ledger["runs"] ?? 0) + 1
        try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}

private final class ProbeSessionProvider: ASREngineProviding {
    let base: ASREngineProvider
    let session: any RecognitionSession
    init(base: ASREngineProvider, session: any RecognitionSession) { self.base = base; self.session = session }
    var hasSherpaEngine: Bool { base.hasSherpaEngine }
    var isSherpaModelLoaded: Bool { base.isSherpaModelLoaded }
    func speechRecognizer() -> SpeechRecognizerController { base.speechRecognizer() }
    func appleEngine() -> AppleSpeechASREngine { base.appleEngine() }
    func sherpaEngine() -> SherpaOnnxASREngine { base.sherpaEngine() }
    func volcengineEngine() -> VolcengineASREngine { base.volcengineEngine() }
    func recognitionSession(for code: String, audioEngine: AudioEngineController) -> any RecognitionSession { session }
    func releaseSherpaEngine() { base.releaseSherpaEngine() }
}

/// 仅记录 Apple 实际识别计数，避免把云端临时稿降级当成 Apple 识别成功。
private final class ProbeSpeechObserver: AppleSpeechRecognizing {
    let inner: any AppleSpeechRecognizing
    private(set) var recognizedCharacters = 0
    private(set) var cachedCharacters = 0
    private(set) var cachedAudioSeconds = 0.0
    private(set) var cachedFrames: Int64 = 0
    private(set) var cachedFinalSeen = false
    init(_ inner: any AppleSpeechRecognizing) { self.inner = inner }
    var currentText: String { inner.currentText }
    func updateLanguage() { inner.updateLanguage() }
    func start(onResult: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void,
               onRequestSwitch: @escaping (SFSpeechAudioBufferRecognitionRequest) -> Void) -> SFSpeechAudioBufferRecognitionRequest? {
        inner.start(onResult: { [weak self] text, final in
            self?.recognizedCharacters = text.count
            onResult(text, final)
        }, onError: onError, onRequestSwitch: onRequestSwitch)
    }
    func stop() -> String {
        let text = inner.stop(); recognizedCharacters = text.count; return text
    }
    func recognize(buffers: [AVAudioPCMBuffer], onResult: @escaping (String, Bool) -> Void,
                   completion: @escaping (String) -> Void) {
        cachedFrames = buffers.reduce(0) { $0 + Int64($1.frameLength) }
        cachedAudioSeconds = buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        inner.recognize(buffers: buffers, onResult: { [weak self] text, final in
            self?.cachedFinalSeen = self?.cachedFinalSeen == true || final
            onResult(text, final)
        }) { [weak self] text in
            self?.cachedCharacters = text.count
            self?.recognizedCharacters = text.count
            completion(text)
        }
    }
}

private final class ProbeFaultProvider: CloudASRProvider {
    let mode: String
    let base = OpenAITranscriptionProvider()
    private let lock = NSLock()
    private var triggerTime: Double?
    private var failureMessage: String?
    var triggeredAt: Double? { lock.lock(); defer { lock.unlock() }; return triggerTime }
    var earlyFailure: String? { lock.lock(); defer { lock.unlock() }; return failureMessage }
    private func markFailure(_ message: String) { lock.lock(); failureMessage = message; lock.unlock() }
    private func markTriggered() {
        lock.lock(); defer { lock.unlock() }
        if triggerTime == nil { triggerTime = ProcessInfo.processInfo.systemUptime }
    }
    init(mode: String) { self.mode = mode }
    var engineCode: String { OpenAIASRSettings.engineCode }
    var displayName: String { "OpenAI" }
    var audioConfiguration: CloudASRAudioConfiguration { base.audioConfiguration }
    var finalResultTimeout: Double { base.finalResultTimeout }
    var requiresFinalConfirmation: Bool { true }
    func validateCredentials() -> String? { nil }
    func createConnection() -> (any CloudASRConnection)? {
        guard case .success(let connection) = prepareConnection() else { return nil }
        return connection
    }
    func prepareConnection() -> Result<any CloudASRConnection, CloudASRFailure> {
        if mode == "start" {
            markTriggered()
            return .failure(.init(kind: .configuration, message: loc("openai.error.configuration")))
        }
        switch base.prepareConnection() {
        case .failure(let failure): markFailure(failure.message); return .failure(failure)
        case .success(let connection):
            return .success(ProbeFaultConnection(inner: connection, mode: mode,
                onFault: { [weak self] in self?.markTriggered() },
                onEarlyFailure: { [weak self] in self?.markFailure($0) }))
        }
    }
}

private final class ProbeFaultConnection: CloudASRConnection, CloudASRConnectionDelegate {
    weak var delegate: CloudASRConnectionDelegate?
    let inner: any CloudASRConnection
    let mode: String
    let onFault: () -> Void
    let onEarlyFailure: (String) -> Void
    private let lock = NSLock()
    private var chunks = 0
    private var failed = false
    init(inner: any CloudASRConnection, mode: String, onFault: @escaping () -> Void, onEarlyFailure: @escaping (String) -> Void) {
        self.inner = inner; self.mode = mode; self.onFault = onFault; self.onEarlyFailure = onEarlyFailure; inner.delegate = self
    }
    func resume() { inner.resume() }
    func sendAudioChunk(_ data: Data, isFinal: Bool) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        chunks += 1
        if mode == "final" && isFinal || mode == "stream" && chunks >= 35 {
            failed = true
            lock.unlock()
            onFault()
            inner.cancel()
            delegate?.connection(self, didFailWithError: .init(kind: .transport, message: loc("openai.error.transport")))
        } else { lock.unlock(); inner.sendAudioChunk(data, isFinal: isFinal) }
    }
    func cancel() { lock.lock(); failed = true; lock.unlock(); inner.cancel() }
    func connectionDidOpen(_ connection: any CloudASRConnection) {
        lock.lock(); let active = !failed; lock.unlock()
        if active { delegate?.connectionDidOpen(self) }
    }
    func connection(_ connection: any CloudASRConnection, didReceiveText text: String, isFinal: Bool) {
        lock.lock(); let active = !failed; lock.unlock()
        if active { delegate?.connection(self, didReceiveText: text, isFinal: isFinal) }
    }
    func connection(_ connection: any CloudASRConnection, didFailWithError error: CloudASRFailure) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        failed = true; lock.unlock()
        onEarlyFailure(error.message)
        delegate?.connection(self, didFailWithError: error)
    }
}

private final class ProbePresenter: RecordingSessionPresenting {
    var isShowingError = false
    var firstTextAt: Double?
    var errorCount = 0
    func present(_ event: RecordingSessionPresentationEvent) {
        if case .updateText(let text) = event, !text.isEmpty, firstTextAt == nil {
            firstTextAt = ProcessInfo.processInfo.systemUptime
        }
        if case .showError = event { errorCount += 1; isShowingError = true }
    }
    func dismiss(completion: (() -> Void)?) { completion?() }
    func updateRecognitionText(_ text: String) { present(.updateText(text)) }
    func showRecognitionRefining() {}
    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) { errorCount += 1; isShowingError = true }
    func dismissRecognition(completion: (() -> Void)?) { completion?() }
    func dismissRecognitionImmediately() {}
}

/// 实际剪贴板事务只粘贴到本进程专用窗口，绝不向用户正在工作的应用发键。
private final class ProbeSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(code: "openai-probe", displayNameKey: "menu.textOutput.paste", iconName: "doc", supportsStreaming: false)
    var deliveryCount = 0
    var completionCount = 0
    var characters = 0
    var deliveredAt: Double?
    var windowReceived = true
    let expectedTail: String?
    var tailMatches: Bool
    private var window: NSWindow?
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
    private var injector: TextInjector?

    init(useWindow: Bool, expectedTail: String?) {
        self.expectedTail = expectedTail
        tailMatches = expectedTail == nil
        windowReceived = !useWindow
        guard useWindow else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AtomVoice · 语音输入自动验收窗口"
        window.isReleasedWhenClosed = false
        textView.isEditable = true
        textView.font = .systemFont(ofSize: 16)
        window.contentView = textView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        app.activate(ignoringOtherApps: true)
        self.window = window
        injector = TextInjector(platform: ProbeInjectionPlatform(textView: textView))
    }

    func deliver(text: String, onSubmission: ((TextDeliverySubmission) -> Void)?, completion: ((TextDeliveryResult) -> Void)?) {
        deliveryCount += 1
        characters += text.count
        tailMatches = expectedTail.map { OpenAILiveProbe.normalized(text).hasSuffix(OpenAILiveProbe.normalized($0)) } ?? true
        deliveredAt = ProcessInfo.processInfo.systemUptime
        if let injector {
            injector.inject(text: text, onSubmission: onSubmission) { [self] result in
                windowReceived = textView.string == text
                completionCount += 1
                completion?(result)
            }
        } else {
            completionCount += 1
            onSubmission?(.eventPosted)
            completion?(.init(submission: .eventPosted, cleanup: .notNeeded))
        }
    }
    func close() { window?.close() }
}

private final class ProbeInjectionPlatform: TextInjectionPlatform {
    let textView: NSTextView
    private let system = SystemTextInjectionPlatform()
    init(textView: NSTextView) { self.textView = textView }
    func target() -> TextInjectionTarget { .init(processID: getpid(), bundleID: Bundle.main.bundleIdentifier, profile: nil) }
    func frontmostProcessID() -> pid_t? { getpid() }
    func preparePaste(for target: TextInjectionTarget) async -> @MainActor () async -> TextDeliverySubmission {
        { [textView] in textView.paste(nil); return .eventPosted }
    }
    func textForInsertion(_ text: String, targetPID: pid_t?) async -> String { text }
    func prepareInputSource() -> TextInjectionInputSource { system.prepareInputSource() }
}
