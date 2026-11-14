import AVFoundation
import Foundation
import Speech
@testable import AtomVoiceCore

enum OpenAICloudRuntimeTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Cloud runtime prepares one connection without a second credential read") {
            let provider = RuntimeCloudProvider()
            let recognizer = CloudASRRecognizerController(provider: provider)
            try expect(recognizer.start(onResult: { _, _ in }, onError: { _ in }) == nil)
            try await waitForAsyncCallbacks()
            try expect(provider.prepareCount == 1)
            try expect(provider.validationCount == 0 && provider.createCount == 0)
            recognizer.cancel()
        }
        await runner.run("Cloud legacy preparation retains validate then create") {
            let provider = LegacyRuntimeCloudProvider()
            if case .failure = provider.prepareConnection() { throw TestFailure(file: #filePath, line: #line, message: "preparation failed") }
            try expect(provider.operations == ["validate", "create"])
        }
        await runner.run("Confirmed-final providers recover partial on timeout while legacy remains unchanged") {
            for strict in [false, true] {
                let provider = RuntimeCloudProvider(strict: strict)
                let recognizer = CloudASRRecognizerController(provider: provider)
                let partialReceived = DispatchSemaphore(value: 0)
                _ = recognizer.start(onResult: { text, _ in
                    if text == "fixture partial" { partialReceived.signal() }
                }, onError: { _ in })
                let resumed = await waitForSignal(provider.connection.resumed, timeout: 2)
                try expect(resumed, "Fake cloud connection did not resume; strict=\(strict)")
                provider.connection.open()
                recognizer.accept(buffer: try require(makePCMBuffer(sampleRate: 24_000, frameLength: 2_400, fillValue: 0.2)))
                provider.connection.emit("fixture partial")
                let received = await waitForSignal(partialReceived, timeout: 2)
                try expect(received, "Partial result did not arrive; strict=\(strict)")
                var results: [(String, String?)] = []
                let stopFinished = DispatchSemaphore(value: 0)
                recognizer.stop {
                    results.append(($0, $1))
                    stopFinished.signal()
                }
                // 等待真实的超时完成回调，覆盖队列和主线程调度，不依赖固定80ms睡眠。
                let finished = await waitForSignal(stopFinished, timeout: 2)
                try expect(finished, "Cloud stop did not finish; strict=\(strict)")
                try expect(results.count == 1)
                try expect(results[0].0 == "fixture partial")
                try expect((results[0].1 != nil) == strict)
            }
        }
        await runner.run("OpenAI registered session reuses one runtime and shares Apple recovery resource") {
            let provider = ASREngineProvider()
            let audio = AudioEngineController(startOperationOverride: { true }, stopOperationOverride: {})
            let first = provider.recognitionSession(for: ASREngineRegistry.openAICode, audioEngine: audio)
            let second = provider.recognitionSession(for: ASREngineRegistry.openAICode, audioEngine: audio)
            try expect((first as AnyObject) === (second as AnyObject))
            try expect(first is CloudRecognitionSession)
            try expect(first.code == "openai")
            try expect(first.preferredAudioFormat == .init(sampleRate: 24_000, channelCount: 1))
            try expect(first.recognitionResources == ["openai", "apple"])
            try expect(!first.supportsLiveInsertion)
            try expect(ASREngineRegistry.shared.isCloud("openai"))
        }
        await runner.run("OpenAI cloud start failure reuses Apple start session") {
            let harness = RuntimeSessionHarness()
            harness.provider.preparationFailure = .init(kind: .configuration, message: "fixture failure")
            var started = false
            harness.session.start(callbacks: harness.callbacks) { result in
                if case .started = result { started = true }
            }
            try await waitForAsyncCallbacks()
            try expect(started && harness.apple.startCount == 1)
            try expect(harness.effectiveEngines == ["apple"])
            var stopped: RecognitionSessionStopResult?
            harness.session.stop(immediate: false, appending: nil, callbacks: harness.callbacks) { stopped = $0 }
            try expect(stopped?.text == "Apple complete fixture")
            harness.session.cancel()
        }
        await runner.run("OpenAI immediate connection failure completes local start exactly once") {
            let harness = RuntimeSessionHarness()
            harness.provider.connection.failsOnResume = true
            var startCount = 0
            harness.session.start(callbacks: harness.callbacks) { result in
                if case .started = result { startCount += 1 }
            }
            try await waitForAsyncCallbacks()
            try expect(startCount == 1 && harness.apple.startCount == 1)
            harness.audio.clearSwitchedRequest()
            harness.session.cancel()
        }
        await runner.run("OpenAI live failure replays the whole unconfirmed recording without duplicating prefix") {
            let harness = RuntimeSessionHarness()
            harness.session.start(callbacks: harness.callbacks) { _ in }
            try await waitForAsyncCallbacks()
            harness.provider.connection.open()
            for _ in 0..<7 {
                harness.callbacks.audioInput.accept(try require(makePCMBuffer(sampleRate: 24_000, frameLength: 24_000, fillValue: 0.1)))
            }
            try await waitForAsyncCallbacks()
            harness.provider.connection.emit("Cloud temporary fixture")
            try await waitForAsyncCallbacks()
            harness.provider.connection.fail()
            try await waitForAsyncCallbacks()
            try expect(harness.apple.startCount == 1)
            try expect(harness.effectiveEngines == ["apple"])
            var stopped: RecognitionSessionStopResult?
            harness.session.stop(immediate: false, appending: nil, callbacks: harness.callbacks) { stopped = $0 }
            try expect(stopped?.text == "Apple complete fixture")
            try expect(harness.apple.cachedRecognitionCount == 0)
            harness.audio.clearSwitchedRequest()
            harness.session.cancel()
        }
        await runner.run("OpenAI final failure runs cached Apple over all unconfirmed audio") {
            let harness = RuntimeSessionHarness()
            harness.provider.finalResultTimeout = 5
            harness.session.start(callbacks: harness.callbacks) { _ in }
            try await waitForAsyncCallbacks()
            harness.provider.connection.open()
            for _ in 0..<7 {
                harness.callbacks.audioInput.accept(try require(makePCMBuffer(sampleRate: 24_000, frameLength: 24_000, fillValue: 0.1)))
            }
            try await waitForAsyncCallbacks()
            harness.provider.connection.emit("Cloud temporary fixture")
            try await waitForAsyncCallbacks()
            var results: [RecognitionSessionStopResult] = []
            harness.callbacks.audioInput.finish {
                harness.session.stop(immediate: false, appending: nil, callbacks: harness.callbacks) { results.append($0) }
            }
            try await waitForAsyncCallbacks()
            harness.provider.connection.fail()
            try await waitForAsyncCallbacks()
            try expect(results.count == 1 && results[0].text == "Apple complete fixture")
            try expect(harness.apple.cachedRecognitionCount == 1)
            try expect(harness.apple.cachedFrames == 7 * 24_000)
            try expect(harness.apple.startCount == 0)
            harness.session.cancel()
        }
        await runner.run("OpenAI transport failure racing stop retains partial and reaches cached Apple once") {
            let harness = RuntimeSessionHarness()
            harness.session.start(callbacks: harness.callbacks) { _ in }
            try await waitForAsyncCallbacks()
            harness.provider.connection.open()
            harness.callbacks.audioInput.accept(try require(makePCMBuffer(sampleRate: 24_000, frameLength: 24_000, fillValue: 0.1)))
            harness.provider.connection.emit("Cloud temporary fixture")
            try await waitForAsyncCallbacks()
            var results: [RecognitionSessionStopResult] = []
            harness.provider.connection.fail()
            harness.session.stop(immediate: false, appending: nil, callbacks: harness.callbacks) { results.append($0) }
            try await waitForAsyncCallbacks()
            try expect(results.count == 1 && results[0].text == "Apple complete fixture")
            try expect(harness.apple.cachedRecognitionCount == 1)
            try expect(harness.apple.startCount == 0)
            harness.session.cancel()
        }
        await runner.run("OpenAI immediate stop uses a snapshot without commit or Apple recovery") {
            let harness = RuntimeSessionHarness()
            harness.session.start(callbacks: harness.callbacks) { _ in }
            try await waitForAsyncCallbacks()
            harness.provider.connection.open()
            harness.provider.connection.emit("Cloud snapshot fixture")
            try await waitForAsyncCallbacks()
            var result: RecognitionSessionStopResult?
            harness.session.stop(immediate: true, appending: "!", callbacks: harness.callbacks) { result = $0 }
            try await waitForAsyncCallbacks()
            try expect(result?.text == "Cloud snapshot fixture")
            try expect(result?.appendingImmediatePunctuation == "!")
            try expect(!harness.provider.connection.finalWasSent)
            try expect(harness.apple.startCount == 0 && harness.apple.cachedRecognitionCount == 0)
            harness.session.cancel()
        }
        await runner.run("OpenAI unconfirmed cache preserves full audio but keeps Doubao five second policy") {
            for strict in [false, true] {
                let fallback = DoubaoFallbackCoordinator(retainsAudioUntilFinal: strict)
                fallback.beginWaitingForFirstResult()
                for _ in 0..<7 {
                    fallback.captureAudioBuffer(try require(makePCMBuffer(sampleRate: 24_000, frameLength: 24_000)), copyBuffer: { $0 })
                }
                _ = fallback.acceptCloudText("fixture")
                let snapshot = fallback.makeFallbackSnapshot(originalError: "fixture", stopLiveFallback: { "" })
                let frames = snapshot.buffers.reduce(0) { $0 + Int($1.frameLength) }
                try expect(frames == (strict ? 7 : 5) * 24_000)
                try expect(snapshot.cloudPrefixText == (strict ? "" : "fixture"))
            }
        }
        await runner.run("Apple handoff serializes history with frames arriving during replay") {
            let input = RecordingAudioInput()
            let fallback = DoubaoFallbackCoordinator(retainsAudioUntilFinal: true)
            let firstCaptured = DispatchSemaphore(value: 0)
            let replayEntered = DispatchSemaphore(value: 0)
            let resumeReplay = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let received = RuntimeAudioSequence()
            var historyReadCount = 0
            defer { resumeReplay.signal(); input.cancel() }

            func frame(_ value: Int) throws -> AVAudioPCMBuffer {
                try require(makePCMBuffer(sampleRate: 24_000, frameLength: 1, fillValue: Float(value)))
            }
            fallback.beginWaitingForFirstResult()
            input.connect { buffer in
                fallback.captureAudioBuffer(buffer, copyBuffer: { $0 })
                if buffer.floatChannelData?[0][0] == 1 { firstCaptured.signal() }
            }
            input.accept(try frame(1))
            let captured = await waitForSignal(firstCaptured, timeout: 2)
            try expect(captured)
            _ = fallback.acceptCloudText("fixture partial")
            _ = fallback.beginAppleLiveFallback()
            // Apple 已进入准备状态、但交接尚未执行，第二帧仍应进入全量历史。
            input.accept(try frame(2))
            input.connect(replaying: {
                historyReadCount += 1
                let history = fallback.liveReplayBuffers()
                replayEntered.signal()
                _ = resumeReplay.wait(timeout: .now() + 2)
                return history
            }) { buffer in
                received.append(Int(buffer.floatChannelData?[0][0] ?? -1))
            }
            let entered = await waitForSignal(replayEntered, timeout: 2)
            try expect(entered)
            // 确定性复现：历史快照已取出、尚未回放时，第三帧进入同一输入队列。
            input.accept(try frame(3))
            resumeReplay.signal()
            input.accept(try frame(4))
            input.finish { finished.signal() }
            let delivered = await waitForSignal(finished, timeout: 2)
            try expect(delivered)
            try expect(historyReadCount == 1)
            try expect(received.values == [1, 2, 3, 4])
        }
    }
}

private final class RuntimeAudioSequence {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func append(_ value: Int) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class RuntimeCloudProvider: CloudASRProvider {
    let engineCode = "openai"
    let displayName = "fixture"
    let connection = RuntimeCloudConnection()
    let requiresFinalConfirmation: Bool
    let audioConfiguration = CloudASRAudioConfiguration(sampleRate: 24_000, connectionTimeout: 5)
    var finalResultTimeout = 0.01
    var preparationFailure: CloudASRFailure?
    private(set) var prepareCount = 0
    private(set) var validationCount = 0
    private(set) var createCount = 0
    init(strict: Bool = true) { requiresFinalConfirmation = strict }
    func validateCredentials() -> String? { validationCount += 1; return nil }
    func createConnection() -> CloudASRConnection? { createCount += 1; return connection }
    func prepareConnection() -> Result<any CloudASRConnection, CloudASRFailure> {
        prepareCount += 1
        if let preparationFailure { return .failure(preparationFailure) }
        return .success(connection)
    }
}

private final class LegacyRuntimeCloudProvider: CloudASRProvider {
    let engineCode = "legacy"
    let displayName = "fixture"
    let finalResultTimeout = 1.0
    var operations: [String] = []
    func validateCredentials() -> String? { operations.append("validate"); return nil }
    func createConnection() -> CloudASRConnection? { operations.append("create"); return RuntimeCloudConnection() }
}

private final class RuntimeCloudConnection: CloudASRConnection {
    weak var delegate: CloudASRConnectionDelegate?
    let resumed = DispatchSemaphore(value: 0)
    var finalWasSent = false
    var failsOnResume = false
    func resume() {
        if failsOnResume { fail() }
        resumed.signal()
    }
    func sendAudioChunk(_ data: Data, isFinal: Bool) { finalWasSent = finalWasSent || isFinal }
    func cancel() {}
    func open() { delegate?.connectionDidOpen(self) }
    func emit(_ text: String) { delegate?.connection(self, didReceiveText: text, isFinal: false) }
    func fail() { delegate?.connection(self, didFailWithError: .init(kind: .transport, message: "fixture transport failure")) }
}

private final class RuntimeAppleRecognizer: AppleSpeechRecognizing {
    var currentText = "Apple complete fixture"
    var startCount = 0
    var cachedRecognitionCount = 0
    var cachedFrames = 0
    func updateLanguage() {}
    func start(onResult: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void,
               onRequestSwitch: @escaping (SFSpeechAudioBufferRecognitionRequest) -> Void) -> SFSpeechAudioBufferRecognitionRequest? {
        startCount += 1
        return SFSpeechAudioBufferRecognitionRequest()
    }
    func stop() -> String { currentText }
    func recognize(buffers: [AVAudioPCMBuffer], onResult: @escaping (String, Bool) -> Void,
                   completion: @escaping (String) -> Void) {
        cachedRecognitionCount += 1
        cachedFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        onResult(currentText, true)
        completion(currentText)
    }
}

private final class RuntimeSessionHarness {
    let provider = RuntimeCloudProvider()
    let apple = RuntimeAppleRecognizer()
    let audio = AudioEngineController(startOperationOverride: { true }, stopOperationOverride: {})
    var effectiveEngines: [String] = []
    lazy var callbacks = RecognitionSessionCallbacks(
        isCurrent: { true }, isRecordingCurrent: { true }, copyAudioBuffer: { $0 },
        onPartialResult: { _, _ in }, onError: { _ in }, onShowRecording: {}, onProgress: { _, _ in },
        onShimmerChanged: { _ in }, onEffectiveEngineChanged: { [weak self] in self?.effectiveEngines.append($0) },
        onWaitingForFinalResultChanged: { _ in }, onResetLiveInsertion: {})
    lazy var session = CloudRecognitionSession(
        cloudEngine: CloudASREngine(provider: provider, descriptor: .openAI),
        appleEngine: AppleSpeechASREngine(recognizer: apple), speechRecognizerProvider: { [apple] in apple },
        audioEngine: audio, privacyAccepted: { true }, privacyErrorKey: "openai.error.privacyNotAccepted",
        fallbackErrorKey: "openai.fallback.withError", validatesCredentialsDuringPreflight: false)
}
