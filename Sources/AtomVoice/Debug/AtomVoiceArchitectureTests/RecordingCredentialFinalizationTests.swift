import Foundation
@testable import AtomVoiceCore

enum RecordingCredentialFinalizationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Recording stop overlaps credentials with ASR and retains busy state until refinement ends") {
            try await completionOrder(settingsFirst: false)
        }
        await runner.run("Recording settings ready before ASR joins once and ignores duplicate ASR completion") {
            try await completionOrder(settingsFirst: true)
        }
        await runner.run("Immediate stop including preparation skips all credential reads and refinement") {
            try await immediateStop()
        }
        await runner.run("Recording cancellation before or after ASR drops late credentials and output") {
            try await cancellation()
        }
        await runner.run("Quick restart delivers old raw text without waiting for credentials or changing new presentation") {
            try await restartAfterASR()
        }
        await runner.run("Quick restart keeps the ASR resource barrier but never waits for old credentials") {
            try await restartBeforeASR()
        }
        await runner.run("Cross-engine restart delivers late old ASR immediately without waiting for old credentials") {
            try await restartWithIndependentEngine()
        }
        await runner.run("Unavailable or disabled refinement delivers raw text and clears recording busy state") {
            try await unavailableCredentials()
        }
        await runner.run("Inapplicable recognition engines never read refinement credentials") {
            try await inapplicableEngines()
        }
        await runner.run("LLM failure delivers raw text and cancellation rejects late LLM callbacks") {
            try await refinementFailureAndCancellation()
        }
        await runner.run("Recording finalization freezes non-LLM settings and uses the stopped session provider") {
            try await frozenSettings()
        }
        await runner.run("Empty ASR result completes while credentials remain blocked") {
            try await emptyResult()
        }
    }

    @MainActor
    private static func completionOrder(settingsFirst: Bool) async throws {
        let fixture = CredentialFinalizationFixture()
        defer { fixture.tearDown() }
        var busy: [Bool] = []
        fixture.controller.onRefiningStateChanged = { busy.append($0) }
        try await start(fixture)
        fixture.controller.stop()
        try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
        try expect(!fixture.key.timedOut && fixture.key.mainThreadReads == 0,
                   "Stop and ASR finish submission must return while the background credential read is blocked")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        try await waitUntil { heartbeat }
        try expect(!fixture.key.timedOut && fixture.sink.deliveredTexts.isEmpty)

        if settingsFirst {
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
            try expect(fixture.refiner.requests.isEmpty && fixture.sink.deliveredTexts.isEmpty,
                       "Credentials alone cannot complete recognition")
            try expect(!fixture.controller.isRefining && busy.isEmpty)
        }
        let stopCompletion = try require(fixture.session.lastStopCompletion)
        fixture.session.completeStop()
        try expect(fixture.controller.isRefining)
        if !settingsFirst {
            try expect(fixture.refiner.requests.isEmpty && fixture.sink.deliveredTexts.isEmpty)
            try expect(busy == [true], "Credential wait must be visible to shortcut and update busy consumers")
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
        }
        try expect(fixture.refiner.requests == ["original"] && fixture.controller.isRefining)
        stopCompletion(.init(text: "duplicate", errorMessage: nil, appendingImmediatePunctuation: nil))
        let refinementCompletion = try require(fixture.refiner.pendingCompletion)
        refinementCompletion("refined", nil)
        try await waitUntil { fixture.sink.deliveredTexts == ["refined"] }
        refinementCompletion("duplicate refinement", nil)
        try await drainMainQueue()
        try expect(fixture.sink.deliveredTexts == ["refined"] && !fixture.controller.isRefining)
        try expect(busy == [true, false] && fixture.key.readCount == 1)
    }

    @MainActor
    private static func immediateStop() async throws {
        for preparing in [false, true] {
            let fixture = CredentialFinalizationFixture()
            defer { fixture.tearDown() }
            fixture.session.completesPreparationImmediately = !preparing
            fixture.controller.start()
            if !preparing {
                try await waitUntil { fixture.controller.state.recognitionReady }
            }
            fixture.controller.stopImmediate(appending: "!")
            fixture.controller.stop()
            if preparing { fixture.session.completePreparation() }
            try await waitUntil { fixture.session.stopCallCount == 1 }
            fixture.session.completeStop()
            try await waitUntil { fixture.sink.deliveredTexts == ["original!"] }
            try await drainSnapshots(fixture.settings)
            try expect(fixture.session.lastStopImmediate && fixture.session.lastStopPunctuation == "!")
            try expect(fixture.key.readCount == 0 && fixture.refiner.requests.isEmpty)
            try expect(!fixture.controller.isRefining)
        }
    }

    @MainActor
    private static func cancellation() async throws {
        for asrFinished in [false, true] {
            let fixture = CredentialFinalizationFixture()
            defer { fixture.tearDown() }
            try await start(fixture)
            fixture.controller.stop()
            try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
            let completion = try require(fixture.session.lastStopCompletion)
            if asrFinished {
                fixture.session.completeStop()
                try expect(fixture.controller.isRefining)
            }
            fixture.controller.cancel()
            try expect(!fixture.controller.isRefining && !fixture.controller.isRecordingOrStarting)
            let eventCount = fixture.harness.presenter.events.count
            let dismissCount = fixture.harness.presenter.dismissCount
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
            completion(.init(text: "late", errorMessage: nil, appendingImmediatePunctuation: nil))
            try await drainMainQueue()
            try expect(fixture.sink.deliveredTexts.isEmpty && fixture.refiner.requests.isEmpty)
            try expect(fixture.harness.presenter.events.count == eventCount)
            try expect(fixture.harness.presenter.dismissCount == dismissCount && !fixture.controller.isRefining)
        }
    }

    @MainActor
    private static func restartAfterASR() async throws {
        let fixture = CredentialFinalizationFixture()
        defer { fixture.tearDown() }
        try await start(fixture)
        fixture.controller.stop()
        try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
        fixture.session.completeStop()
        try expect(fixture.controller.isRefining && fixture.sink.deliveredTexts.isEmpty)
        let oldGeneration = fixture.controller.recordingGeneration
        fixture.controller.start()
        try await waitUntil { fixture.session.startCallCount == 2 && fixture.controller.state.recognitionReady }
        try expect(fixture.controller.recordingGeneration != oldGeneration)
        try expect(fixture.sink.deliveredTexts == ["original"] && fixture.refiner.requests.isEmpty)
        try expect(fixture.controller.isRecording && !fixture.controller.isRefining && !fixture.key.timedOut)
        let eventCount = fixture.harness.presenter.events.count
        let dismissCount = fixture.harness.presenter.dismissCount
        fixture.key.release()
        try await drainSnapshots(fixture.settings)
        try expect(fixture.refiner.requests.isEmpty && fixture.sink.deliveredTexts == ["original"])
        try expect(fixture.harness.presenter.events.count == eventCount)
        try expect(fixture.harness.presenter.dismissCount == dismissCount && fixture.controller.isRecording)
    }

    @MainActor
    private static func restartBeforeASR() async throws {
        for settingsFirst in [false, true] {
            let fixture = CredentialFinalizationFixture()
            defer { fixture.tearDown() }
            try await start(fixture)
            fixture.controller.stop()
            try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
            if settingsFirst {
                fixture.key.release()
                try await drainSnapshots(fixture.settings)
            }
            let cancelCount = fixture.session.cancelCount
            fixture.controller.start()
            // 等本轮准备回调进入主队列，仍只能等旧 ASR 的资源屏障。
            try await drainMainQueue()
            try expect(fixture.session.startCallCount == 1 && fixture.session.cancelCount == cancelCount)
            fixture.session.completeStop()
            try await waitUntil { fixture.session.startCallCount == 2 && fixture.controller.state.recognitionReady }
            try expect(fixture.sink.deliveredTexts == ["original"] && fixture.refiner.requests.isEmpty,
                       "A superseded result may deliver raw text but cannot start old LLM work")
            try expect(fixture.controller.isRecording && !fixture.controller.isRefining && !fixture.key.timedOut)
            let eventCount = fixture.harness.presenter.events.count
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
            try expect(fixture.harness.presenter.events.count == eventCount && fixture.controller.isRecording)
            try expect(fixture.refiner.requests.isEmpty && fixture.sink.deliveredTexts == ["original"])
        }
    }

    @MainActor
    private static func restartWithIndependentEngine() async throws {
        let fixture = CredentialFinalizationFixture()
        defer { fixture.tearDown() }
        try await start(fixture)
        fixture.controller.stop()
        try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
        let nextSession = FakeRecognitionSession(code: ASREngineRegistry.appleCode)
        fixture.harness.provider.register(nextSession)
        AppSettings.recognitionEngine = nextSession.code
        fixture.controller.start()
        try await waitUntil { nextSession.startCallCount == 1 && fixture.controller.state.recognitionReady }
        let eventCount = fixture.harness.presenter.events.count
        let dismissCount = fixture.harness.presenter.dismissCount
        fixture.session.completeStop()
        try expect(fixture.sink.deliveredTexts == ["original"] && !fixture.key.timedOut,
                   "Old generation cannot refine, so its final result must not wait for credentials")
        try expect(fixture.controller.isRecording && !fixture.controller.isRefining)
        fixture.key.release()
        try await drainSnapshots(fixture.settings)
        try expect(fixture.refiner.requests.isEmpty && fixture.sink.deliveredTexts == ["original"])
        try expect(fixture.harness.presenter.events.count == eventCount)
        try expect(fixture.harness.presenter.dismissCount == dismissCount && fixture.controller.isRecording)
    }

    @MainActor
    private static func unavailableCredentials() async throws {
        for result in [KeychainStringReadResult.notFound, .failure(-1), .value(" \n")] {
            let fixture = CredentialFinalizationFixture(readResult: result)
            defer { fixture.tearDown() }
            try await start(fixture)
            fixture.controller.stop()
            try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
            fixture.session.completeStop()
            try expect(fixture.controller.isRefining)
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
            try expect(fixture.sink.deliveredTexts == ["original"] && !fixture.controller.isRefining)
            try expect(fixture.refiner.requests.isEmpty && fixture.key.readCount == 1)
        }
        let disabled = CredentialFinalizationFixture()
        defer { disabled.tearDown() }
        disabled.settings.enabled = false
        try await start(disabled)
        disabled.controller.stop()
        try await waitUntil { disabled.session.stopCallCount == 1 }
        disabled.session.completeStop()
        try await drainSnapshots(disabled.settings)
        try expect(disabled.sink.deliveredTexts == ["original"] && !disabled.controller.isRefining)
        try expect(disabled.refiner.requests.isEmpty && disabled.key.readCount == 0)
    }

    @MainActor
    private static func inapplicableEngines() async throws {
        for engine in [ASREngineRegistry.appleCode, ASREngineRegistry.sherpaCode, VolcengineASRSettings.engineCode] {
            let fixture = CredentialFinalizationFixture(engine: engine)
            defer { fixture.tearDown() }
            try await start(fixture)
            fixture.controller.stop()
            try await waitUntil { fixture.session.stopCallCount == 1 }
            fixture.session.completeStop()
            try await drainSnapshots(fixture.settings)
            try expect(fixture.sink.deliveredTexts == ["original"] && !fixture.controller.isRefining)
            try expect(fixture.key.readCount == 0 && fixture.refiner.requests.isEmpty)
        }
    }

    @MainActor
    private static func refinementFailureAndCancellation() async throws {
        for cancel in [false, true] {
            let fixture = CredentialFinalizationFixture()
            defer { fixture.tearDown() }
            if !cancel {
                fixture.refiner.delayCompletion = false
                fixture.refiner.nextError = "offline fixture failure"
            }
            try await start(fixture)
            fixture.controller.stop()
            try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
            fixture.session.completeStop()
            fixture.key.release()
            try await drainSnapshots(fixture.settings)
            if cancel {
                try expect(fixture.controller.isRefining && fixture.refiner.requests == ["original"])
                let completion = try require(fixture.refiner.pendingCompletion)
                let generation = fixture.controller.recordingGeneration
                fixture.controller.cancel()
                try expect(fixture.controller.recordingGeneration > generation && fixture.controller.state.phase == .cancelled,
                           "Cancelling pending LLM must execute the recording cancellation transition")
                let eventCount = fixture.harness.presenter.events.count
                fixture.refiner.pendingOnProgress?("late progress")
                completion(nil, "offline fixture failure")
                try await drainMainQueue()
                try expect(fixture.sink.deliveredTexts.isEmpty && fixture.harness.presenter.events.count == eventCount)
            } else {
                try await waitUntil { fixture.sink.deliveredTexts == ["original"] }
                try expect(fixture.refiner.requests == ["original"])
            }
            try expect(!fixture.controller.isRefining)
        }
    }

    @MainActor
    private static func frozenSettings() async throws {
        let processor = FakeTextProcessor(id: "snapshot", output: nil)
        let fixture = CredentialFinalizationFixture(processors: [processor])
        defer { fixture.tearDown() }
        let oldPunctuation = UserDefaults.standard.object(forKey: AppSettings.Keys.autoPunctuationEnabled)
        defer { restoreDefaultsObject(oldPunctuation, forKey: AppSettings.Keys.autoPunctuationEnabled) }
        AppSettings.selectedLanguage = "en-US"
        AppSettings.autoPunctuationEnabled = false
        try await start(fixture)
        // 用户在收音期间切换全局引擎，不改变原 session 的润色供应商。
        AppSettings.recognitionEngine = ASREngineRegistry.appleCode
        fixture.controller.stop()
        try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
        AppSettings.selectedLanguage = "ja-JP"
        AppSettings.autoPunctuationEnabled = true
        fixture.settings.model = "later-model"
        fixture.settings.systemPrompt = "later-prompt"
        fixture.session.completeStop()
        fixture.key.release()
        try await drainSnapshots(fixture.settings)
        try expect(processor.lastContext?.language == "en-US")
        try expect(processor.lastContext?.autoPunctuationEnabled == false)
        try expect(processor.lastContext?.engineCode == ASREngineRegistry.openAICode)
        let configuration = try require(fixture.refiner.configurations.first)
        try expect(configuration.connection.model == "fixture-model" && configuration.systemPrompt == "fixture-prompt")
        try expect(fixture.key.readCount == 1)
        fixture.refiner.pendingCompletion?("refined", nil)
        try await waitUntil { fixture.sink.deliveredTexts == ["refined"] }
    }

    @MainActor
    private static func emptyResult() async throws {
        let fixture = CredentialFinalizationFixture()
        defer { fixture.tearDown() }
        fixture.session.currentText = ""
        try await start(fixture)
        fixture.controller.stop()
        try await waitUntil { fixture.key.entered && fixture.session.stopCallCount == 1 }
        fixture.session.completeStop()
        try expect(!fixture.controller.isRefining && fixture.harness.presenter.dismissCount == 1)
        try expect(fixture.sink.deliveredTexts.isEmpty && !fixture.key.timedOut)
        fixture.key.release()
        try await drainSnapshots(fixture.settings)
        try expect(fixture.refiner.requests.isEmpty && fixture.harness.presenter.dismissCount == 1)
    }

    @MainActor
    private static func start(_ fixture: CredentialFinalizationFixture) async throws {
        fixture.controller.start()
        try await waitUntil { fixture.controller.state.recognitionReady }
    }

    @MainActor
    private static func drainSnapshots(_ settings: LLMSettings) async throws {
        var drained = false
        // 同一生产队列的后续请求不读密钥；它回到主队列时，前一个快照回调已处理。
        settings.readRuntimeSnapshotAsync(forRecognitionEngine: ASREngineRegistry.appleCode) { _ in drained = true }
        try await waitUntil { drained }
    }

    @MainActor
    private static func drainMainQueue() async throws {
        var drained = false
        DispatchQueue.main.async { drained = true }
        try await waitUntil { drained }
    }

    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TestFailure(file: #filePath, line: #line, message: "Credential finalization operation timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class CredentialFinalizationFixture {
    let preferences = RecordingSessionTestSettings()
    let key: FinalizationKeyStore
    let settings: LLMSettings
    let session: FakeRecognitionSession
    let refiner = FakeRecognitionRefiner()
    let harness: RecordingSessionHarness
    var controller: RecordingSessionController { harness.controller }
    var sink: FakeTextOutputSink { harness.outputSink }

    init(readResult: KeychainStringReadResult = .value("offline-fixture"), processors: [TextPostProcessor] = [],
         engine: String = ASREngineRegistry.openAICode) {
        key = FinalizationKeyStore(result: readResult)
        settings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: key)
        settings.enabled = true
        settings.apiBaseURL = "https://api.openai.com/v1"
        settings.model = "fixture-model"
        settings.systemPrompt = "fixture-prompt"
        session = FakeRecognitionSession(code: engine, currentText: "original")
        session.completesStopImmediately = false
        refiner.delayCompletion = true
        harness = RecordingSessionHarness(session: session, processors: processors,
                                          finalizationLLMSettings: settings, resultRefiner: refiner)
        preferences.apply()
        AppSettings.recognitionEngine = engine
    }

    func tearDown() {
        controller.cancel()
        key.release()
        harness.tearDown()
        preferences.restore()
    }
}

private final class FinalizationKeyStore: LLMAPIKeyStoring {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let result: KeychainStringReadResult
    private var reads = 0
    private var mainReads = 0
    private var expired = false
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var mainThreadReads: Int { lock.lock(); defer { lock.unlock() }; return mainReads }
    var entered: Bool { readCount > 0 }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }

    init(result: KeychainStringReadResult) { self.result = result }

    func readResult() -> KeychainStringReadResult {
        lock.lock()
        reads += 1
        if Thread.isMainThread { mainReads += 1 }
        lock.unlock()
        let timeout = gate.wait(timeout: .now() + 5) == .timedOut
        lock.lock(); expired = expired || timeout; lock.unlock()
        return result
    }

    func release() { gate.signal() }
    func write(_ value: String) -> Bool { false }
    func delete() -> Bool { false }
}
