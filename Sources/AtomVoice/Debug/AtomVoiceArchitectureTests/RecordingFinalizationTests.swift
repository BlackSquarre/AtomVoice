import Foundation
@testable import AtomVoiceCore

enum RecordingFinalizationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Rapid rerecord captures before old stop and reuses recognizer only after final") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "old")
            session.completesStopImmediately = false
            session.connectsAudioInput = true
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            let oldCompletion = try require(session.lastStopCompletion)
            harness.controller.start()
            try await waitForAsyncCallbacks()
            try expect(harness.controller.state.isStarting)
            try expect(session.startCallCount == 1)
            try expect(harness.outputSink.deliveredTexts.isEmpty)
            harness.audioEngine.router.receive(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.3)))
            session.completeStop()
            try await waitForAsyncCallbacks()
            try expect(harness.outputSink.deliveredTexts == ["old"])
            try expect(session.startCallCount == 2 && harness.controller.isRecording)
            try expect(session.receivedAudioBuffers.contains { $0.frameLength == 160 })
            let dismissCount = harness.presenter.dismissCount
            oldCompletion(.init(text: "duplicate", errorMessage: nil, appendingImmediatePunctuation: nil))
            try expect(harness.outputSink.deliveredTexts == ["old"])
            try expect(harness.presenter.dismissCount == dismissCount)
            harness.controller.cancel()
        }
        await runner.run("Rapid rerecord preserves admitted tail frames behind a blocked old consumer") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "old")
            session.connectsAudioInput = true
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var shouldBlock = true
            session.onConsumeAudio = { _ in
                if shouldBlock {
                    shouldBlock = false
                    entered.signal()
                    release.wait()
                }
            }
            defer { release.signal() }
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.audioEngine.router.receive(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.1)))
            let didEnter = await waitForSignal(entered, timeout: 1)
            try expect(didEnter)
            harness.audioEngine.router.receive(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.2)))
            harness.controller.stop()
            harness.controller.start()
            try await waitForAsyncCallbacks()
            try expect(session.stopCallCount == 0 && session.startCallCount == 1)
            release.signal()
            try await waitForAsyncCallbacks()
            try await waitForAsyncCallbacks()
            try expect(session.receivedAudioBuffers.count == 2)
            try expect(approximatelyEqual(session.receivedAudioBuffers[0].floatChannelData![0][0], 0.1))
            try expect(approximatelyEqual(session.receivedAudioBuffers[1].floatChannelData![0][0], 0.2))
            try expect(session.stopCallCount == 1 && session.startCallCount == 2)
            try expect(harness.outputSink.deliveredTexts == ["old"])
            harness.controller.cancel()
        }
        await runner.run("Independent recognition resource starts while prior final remains owned") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let old = FakeRecognitionSession(currentText: "old")
            old.completesStopImmediately = false
            let next = FakeRecognitionSession(code: ASREngineRegistry.sherpaCode)
            let harness = RecordingSessionHarness(session: old)
            harness.provider.register(next)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            AppSettings.recognitionEngine = ASREngineRegistry.sherpaCode
            harness.controller.start()
            try await waitForAsyncCallbacks()
            try expect(next.startCallCount == 1 && harness.controller.isRecording)
            try expect(old.cancelCount == 0)
            let dismissCount = harness.presenter.dismissCount
            old.completeStop()
            try await waitForAsyncCallbacks()
            try expect(harness.outputSink.deliveredTexts == ["old"])
            try expect(harness.presenter.dismissCount == dismissCount)
            try expect(harness.controller.isRecording)
            harness.controller.cancel()
        }
        await runner.run("Explicit cancel invalidates stopped result and ignores late completion") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "discarded")
            session.completesStopImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            harness.controller.cancel()
            let dismissCount = harness.presenter.dismissCount
            session.completeStop()
            try await waitForAsyncCallbacks()
            try expect(harness.outputSink.deliveredTexts.isEmpty)
            try expect(harness.presenter.dismissCount == dismissCount)
        }
        await runner.run("Cancel during asynchronous punctuation rejects late processed output") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let processor = DeferredRecordingFinalProcessor()
            let harness = RecordingSessionHarness(session: FakeRecognitionSession(currentText: "discarded"), processors: [processor])
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            try expect(processor.completion != nil)
            try expect(harness.outputSink.deliveredTexts.isEmpty)
            harness.controller.cancel()
            processor.completion?("discarded.")
            try expect(harness.outputSink.deliveredTexts.isEmpty)
        }
        await runner.run("Cancel while live submission is unresolved rejects late final remainder") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            AppSettings.appleLiveInsertionEnabled = true
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            sink.reportsSubmissionsImmediately = false
            let session = FakeRecognitionSession()
            let harness = RecordingSessionHarness(session: session, outputSink: sink)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            session.emitPartial("Hello. tail")
            try expect(sink.deliveredTexts == ["Hello. "])
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            harness.controller.cancel()
            sink.submitNextDelivery(.eventPosted)
            sink.completeNextDelivery()
            try await waitForAsyncCallbacks()
            try expect(sink.deliveredTexts == ["Hello. "])
        }
        await runner.run("Explicit cancel cancels a submitted recognition start and rejects late start completion") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession()
            session.completesStartImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            try expect(session.startCallCount == 1)
            harness.controller.cancel()
            try expect(session.cancelCount == 1)
            let dismissCount = harness.presenter.dismissCount
            session.completeNextStart()
            try await waitForAsyncCallbacks()
            try expect(!harness.controller.isRecordingOrStarting)
            try expect(harness.presenter.dismissCount == dismissCount)
            harness.controller.cancel()
            try expect(session.cancelCount == 1)
        }
        await runner.run("Reducer keeps the first preparation stop mode until recognition becomes ready") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(&state, .startValidated(engine: ASREngineRegistry.appleCode, lowerVolume: false))
            step(&state, .preparationStopRequested(.init(immediate: true, punctuation: "!")))
            step(&state, .preparationStopRequested(.init(immediate: false, punctuation: nil)))
            let effects = step(&state, .sessionStartCompleted(generation: state.recordingGeneration))
            try expect(state.phase == .stopping && state.recognitionReady)
            try expect(state.preparationStop == nil)
            try expect(effects.contains(.stopSession(generation: state.recordingGeneration, immediate: true, appending: "!")))
            try expect(!effects.contains(.startSilenceMonitor))
        }
    }
}

private final class DeferredRecordingFinalProcessor: TextPostProcessor {
    let id = "deferred-recording-final"
    var completion: ((String?) -> Void)?
    func tryProcess(_ text: String, context: TextProcessingContext) -> String? { nil }
    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void) {
        self.completion = completion
    }
}
