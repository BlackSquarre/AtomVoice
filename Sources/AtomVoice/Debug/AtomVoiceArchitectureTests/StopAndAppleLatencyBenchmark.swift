import AVFoundation
import Foundation
@testable import AtomVoiceCore

/// 正式控制器前后对比。只替换耗时边界，不复制或重排生产 stop/finalize 路径。
enum StopAndAppleLatencyBenchmark {
    @MainActor
    static func runStop() async -> [String: Any] {
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments[AppSettings.Keys.selectedLanguage] = "en-US"
        arguments[AppSettings.Keys.recognitionEngine] = "openai"
        arguments[AppSettings.Keys.llmEnabled] = false
        arguments[AppSettings.Keys.llmResultDelay] = 0.0
        arguments[AppSettings.Keys.appleLiveInsertionEnabled] = false
        arguments[AppSettings.Keys.lowerVolumeOnRecording] = false
        arguments[AppSettings.Keys.autoPunctuationEnabled] = false
        arguments[AppSettings.Keys.textOutputSink] = "latency-fixture"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        var rows: [[String: Any]] = []
        for credentialMS in [0.0, 20.0, 150.0] {
            for asrMS in [100.0, 300.0] {
                for immediate in [false, true] {
                    var returned: [Double] = [], delivered: [Double] = [], asrStarted: [Double] = []
                    var reads: [Int] = [], refines: [Int] = [], failures = 0
                    for repetition in 0..<4 {
                        let keyStore = StopBenchmarkKeyStore(delayMS: credentialMS)
                        let llmSettings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: keyStore)
                        llmSettings.enabled = true
                        llmSettings.apiBaseURL = "https://api.openai.com/v1"
                        llmSettings.model = "offline-model"
                        let audio = AudioEngineController(startOperationOverride: { true }, stopOperationOverride: {})
                        let presenter = FakeRecordingSessionPresenter()
                        let session = StopBenchmarkRecognitionSession(delayMS: asrMS)
                        let provider = FakeASREngineProvider(sessions: [session.code: session])
                        let sink = FakeTextOutputSink(code: "latency-fixture")
                        let refiner = FakeRecognitionRefiner()
                        refiner.nextResult = "offline refined fixture"
                        let controller = RecordingSessionController(
                            audioEngine: audio, presenter: presenter, llmRefiner: LLMRefiner(),
                            textPostProcessorRegistry: TextPostProcessorRegistry(processors: []),
                            textOutputSinkRegistry: TextOutputSinkRegistry(sinks: [sink], fallbackCode: sink.descriptor.code),
                            volumeController: VolumeController(), asrEngineRegistry: .shared, asrEngineProvider: provider,
                            finalizationLLMSettings: llmSettings, resultRefiner: refiner)
                        // 使用与架构测试相同的 reducer 建立已经在录音的状态，不启动硬件或云服务。
                        var state = RecordingSessionState()
                        _ = step(&state, .triggerPressed(deferCapsulePresentation: false))
                        _ = step(&state, .inputPreflightCompleted(request: state.startRequestGeneration, ready: true))
                        _ = step(&state, .recognitionCapabilitiesResolved(mutableCapsulePreview: false))
                        _ = step(&state, .startValidated(engine: session.code, lowerVolume: false))
                        _ = step(&state, .sessionStartCompleted(generation: state.recordingGeneration))
                        controller.state = state
                        controller.recognitionSession = session
                        controller.recognitionSessionStarted = true
                        let started = ProcessInfo.processInfo.systemUptime
                        var delivery: Double?
                        sink.onDeliver = { delivery = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                        if immediate { controller.stopImmediate(appending: nil) } else { controller.stop() }
                        let callReturn = (ProcessInfo.processInfo.systemUptime - started) * 1000
                        while delivery == nil && ProcessInfo.processInfo.systemUptime - started < 5 {
                            try? await Task.sleep(nanoseconds: 500_000)
                        }
                        if repetition > 0 {
                            returned.append(callReturn)
                            delivered.append(delivery ?? -1)
                            asrStarted.append(session.stopStartedAt.map { ($0 - started) * 1000 } ?? -1)
                            reads.append(keyStore.reads)
                            refines.append(refiner.requests.count)
                            if delivery == nil || sink.deliveredTexts.count != 1 { failures += 1 }
                        }
                        controller.asrSilenceMonitor.stop()
                        controller.recognitionSession?.cancel()
                        controller.recordingAudioInput.cancel()
                        // 让上一轮完成收尾再进入下一轮，避免污染计时。
                        await Task.yield()
                    }
                    rows.append(["credential_ms": credentialMS, "asr_ms": asrMS, "immediate": immediate,
                                 "stop_return_ms": summary(returned), "asr_stop_started_ms": summary(asrStarted),
                                 "delivery_ms": summary(delivered), "key_reads": reads, "refiner_calls": refines,
                                 "failed_samples": failures])
                }
            }
        }
        return ["variant": variant, "warmup": 1, "samples": 3, "rows": rows,
                "scope": "Real RecordingSessionController.stop/stopImmediate and finalizer; fake credential/ASR/sink/refiner; no recording or network; delivery means fake sink submission, not target app receipt"]
    }

    /// 每个进程只测一轮；由外部串行启动 11 次。marker 是准备路径边界，不是麦克风首帧。
    @MainActor
    static func runAppleConstruction() -> [String: Any] {
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments[AppSettings.Keys.selectedLanguage] = "en-US"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let start = ProcessInfo.processInfo.systemUptime
        let provider = ASREngineProvider()
        let recognizer = provider.speechRecognizer()
        let marker = ProcessInfo.processInfo.systemUptime
        #if !STOP_APPLE_BASELINE
        recognizer.prepareRecognizerIfNeeded()
        #endif
        let prepared = ProcessInfo.processInfo.systemUptime
        let reuseStart = ProcessInfo.processInfo.systemUptime
        let reused = provider.speechRecognizer()
        #if !STOP_APPLE_BASELINE
        reused.prepareRecognizerIfNeeded()
        #endif
        let reusedAt = ProcessInfo.processInfo.systemUptime
        return ["variant": variant, "pid": ProcessInfo.processInfo.processIdentifier,
                "preparation_marker_ms": (marker - start) * 1000,
                "after_marker_preparation_ms": (prepared - marker) * 1000,
                "total_construction_ms": (prepared - start) * 1000,
                "reuse_ms": (reusedAt - reuseStart) * 1000,
                "same_owner": recognizer === reused,
                "scope": "Real ASREngineProvider/SpeechRecognizerController/SFSpeechRecognizer construction only; no permission request, Speech task, microphone or audio buffer. Marker is not actual capture readiness."]
    }

    private static var variant: String {
        #if STOP_APPLE_BASELINE
        return "before"
        #else
        return "after"
        #endif
    }
    private static func summary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        return ["median": sorted[sorted.count / 2], "min": sorted.first ?? -1, "max": sorted.last ?? -1, "raw": values]
    }
}

private final class StopBenchmarkKeyStore: LLMAPIKeyStoring {
    private let delayMS: Double
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(delayMS: Double) { self.delayMS = delayMS }
    func readResult() -> KeychainStringReadResult {
        lock.lock(); count += 1; lock.unlock()
        if delayMS > 0 { Thread.sleep(forTimeInterval: delayMS / 1000) }
        return .value("offline-fixture-key")
    }
    func write(_ value: String) -> Bool { false }
    func delete() -> Bool { false }
}

private final class StopBenchmarkRecognitionSession: RecognitionSession {
    let code = "openai"
    let currentText = "offline recognition fixture"
    let supportsMutableCapsulePreview = false
    let supportsLiveInsertion = false
    let preferredAudioFormat: AudioRouter.ConsumerFormat? = nil
    private let delayMS: Double
    private var cancelled = false
    private(set) var stopStartedAt: Double?
    init(delayMS: Double) { self.delayMS = delayMS }
    func start(callbacks: RecognitionSessionCallbacks, completion: @escaping (RecognitionSessionStartResult) -> Void) {
        completion(.started)
    }
    func stop(immediate: Bool, appending punctuation: String?, callbacks: RecognitionSessionCallbacks,
              completion: @escaping (RecognitionSessionStopResult) -> Void) {
        stopStartedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + delayMS / 1000) { [self] in
            guard !cancelled else { return }
            completion(.init(text: currentText, errorMessage: nil, appendingImmediatePunctuation: punctuation))
        }
    }
    func cancel() { cancelled = true }
}
