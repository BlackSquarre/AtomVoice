import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum RecordingSessionControllerTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Stopped recording keeps optimizing until final then immediately hides before paste cleanup") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "hello")
            session.completesStopImmediately = false
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            let harness = RecordingSessionHarness(session: session, outputSink: sink)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            try expect(!harness.controller.isRecordingOrStarting)
            try expect(harness.presenter.events.last == .showOptimizing)
            try expect(harness.presenter.dismissCount == 0)
            harness.controller.stop()
            session.emitPartial("hello again")
            session.emitError("late runtime error")
            session.lastStopCallbacks?.onShowRecording()
            session.lastStopCallbacks?.onProgress("late progress", false)
            try await waitForAsyncCallbacks()
            try expect(session.stopCallCount == 1)
            try expect(harness.presenter.events.last == .showOptimizing)
            try expect(harness.presenter.dismissCount == 0)
            session.completeStop()
            try expect(sink.deliveredTexts == ["hello again"])
            try expect(harness.presenter.dismissCount == 1)
            try expect(harness.presenter.immediateDismissCount == 1)
            harness.controller.stop()
            try expect(harness.presenter.dismissCount == 1)
            sink.completeNextDelivery()
            try expect(harness.presenter.dismissCount == 1)
        }

        await runner.run("Stopped fallback changes effective engine without replacing optimizing presentation") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession()
            session.completesStopImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.state.currentRecordingEngine = VolcengineASRSettings.engineCode
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            session.lastStopCallbacks?.onEffectiveEngineChanged(ASREngineRegistry.appleCode)
            try expect(harness.controller.state.currentRecordingEngine == ASREngineRegistry.appleCode)
            try expect(harness.presenter.events.last == .showOptimizing)
            try expect(harness.presenter.dismissCount == 0)
        }

        await runner.run("Preparing stop keeps optimizing and preserves first immediate stop mode") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "hello")
            session.completesPreparationImmediately = false
            let processor = FakeTextProcessor(id: "context", output: "hello")
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            let harness = RecordingSessionHarness(session: session, outputSink: sink, processors: [processor])
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stopImmediate(appending: nil)
            harness.controller.stop()
            try expect(harness.presenter.events.last == .showOptimizing)
            try expect(harness.presenter.dismissCount == 0)
            session.completePreparation()
            try await waitForAsyncCallbacks()
            try await waitForAsyncCallbacks()
            try expect(session.stopCallCount == 1)
            try expect(session.lastStopImmediate)
            try expect(processor.lastContext?.isImmediateFinish == true)
            try expect(harness.presenter.dismissCount == 1)
            try expect(harness.presenter.immediateDismissCount == 1)
            sink.completeNextDelivery()
            try expect(harness.presenter.dismissCount == 1)
        }

        await runner.run("New recording presentation survives old output completion") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            let harness = RecordingSessionHarness(session: FakeRecognitionSession(currentText: "old"), outputSink: sink)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            try expect(sink.deliveredTexts == ["old"])
            harness.controller.start()
            try await waitForAsyncCallbacks()
            let dismissCount = harness.presenter.dismissCount
            sink.completeNextDelivery()
            try expect(harness.controller.isRecording)
            try expect(harness.presenter.dismissCount == dismissCount)
        }

        await runner.run("Stop hides after final even while the last live insertion transaction continues") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            AppSettings.appleLiveInsertionEnabled = true
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            let session = FakeRecognitionSession()
            let harness = RecordingSessionHarness(session: session, outputSink: sink)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            session.emitPartial("Hello.", isFinal: true)
            try expect(sink.deliveredTexts == ["Hello."])
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            try expect(harness.presenter.dismissCount == 1)
            try expect(harness.presenter.immediateDismissCount == 1)
            sink.completeNextDelivery()
            try expect(sink.deliveredTexts == ["Hello."])
            try expect(harness.presenter.dismissCount == 1)
        }

        await runner.run("Final tail is queued before a new recording while live paste is in flight") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            AppSettings.appleLiveInsertionEnabled = true
            let sink = FakeTextOutputSink(completesDeliveriesImmediately: false)
            let session = FakeRecognitionSession()
            let harness = RecordingSessionHarness(session: session, outputSink: sink)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            session.emitPartial("Hello. remaining tail")
            try expect(sink.deliveredTexts == ["Hello. "])
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            // 在第一笔粘贴尚未完成时，尾文也必须已经提交到同一输出队列。
            try expect(sink.deliveredTexts == ["Hello. ", "remaining tail"])
            try expect(harness.presenter.dismissCount == 1)
            harness.controller.start()
            try await waitForAsyncCallbacks()
            let dismissCount = harness.presenter.dismissCount
            sink.completeNextDelivery()
            sink.completeNextDelivery()
            try expect(harness.controller.isRecording)
            try expect(harness.presenter.dismissCount == dismissCount)
            try expect(sink.deliveredTexts == ["Hello. ", "remaining tail"])
        }

        await runner.run("Recording session fixture starts fake recognition without real audio input") {
            let settings = RecordingSessionTestSettings()
            settings.apply(outputSinkCode: "fake-streaming")
            defer { settings.restore() }

            let streamSession = FakeTextStreamSession()
            let outputSink = FakeTextOutputSink(
                code: "fake-streaming",
                supportsStreaming: true,
                streamSession: streamSession
            )
            let recognitionSession = FakeRecognitionSession(preferredAudioFormat: .voice16k)
            let harness = RecordingSessionHarness(session: recognitionSession, outputSink: outputSink)
            defer { harness.tearDown() }

            let request = harness.enterStarting()
            harness.controller.continueStartRecording(startRequest: request)
            try await waitForAsyncCallbacks()

            try expect(harness.provider.requestedRecognitionCodes == [ASREngineRegistry.appleCode])
            try expect(recognitionSession.startCallCount == 1)
            try expect(recognitionSession.startAudioFormats.first == .voice16k)
            try expect(outputSink.beginStreamCount == 1)
            try expect(harness.controller.streamSession === streamSession)
        }

        await runner.run("Recording session fixture copies fake audio input through callbacks") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }

            let harness = RecordingSessionHarness()
            defer { harness.tearDown() }
            let generation = harness.enterCapturing()
            let callbacks = harness.controller.makeRecognitionSessionCallbacks(generation: generation)
            harness.session.start(audioFormat: nil, callbacks: callbacks) { _ in }

            let source = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.25))
            let copy = try require(harness.session.acceptAudio(source))

            try expect(copy !== source)
            try expect(copy.frameLength == source.frameLength)
            try expect(copy.format.sampleRate == source.format.sampleRate)
            try expect(harness.session.copiedAudioBuffers.count == 1)
            try expect(approximatelyEqual(copy.floatChannelData?[0][0] ?? 0, source.floatChannelData?[0][0] ?? 1))
        }

        await runner.run("Recording session auto-hides capsule partials when model disables mutable preview") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }

            let recognitionSession = FakeRecognitionSession(supportsMutableCapsulePreview: false)
            let harness = RecordingSessionHarness(session: recognitionSession)
            defer { harness.tearDown() }

            let request = harness.enterStarting()
            harness.controller.continueStartRecording(startRequest: request)
            try await waitForAsyncCallbacks()

            recognitionSession.emitPartial("hello")

            try expect(!harness.presenter.events.contains(.updateText("hello")))
        }

        await runner.run("Recording session keeps capsule partial rewrites enabled for supported models") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }

            let recognitionSession = FakeRecognitionSession(supportsMutableCapsulePreview: true)
            let harness = RecordingSessionHarness(session: recognitionSession)
            defer { harness.tearDown() }

            let request = harness.enterStarting()
            harness.controller.continueStartRecording(startRequest: request)
            try await waitForAsyncCallbacks()

            recognitionSession.emitPartial("hello")

            try expect(harness.presenter.events.contains(.updateText("hello")))
        }

        await runner.run("Recording session ignores a late start failure after cancel") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }

            let recognitionSession = FakeRecognitionSession()
            recognitionSession.completesStartImmediately = false
            let harness = RecordingSessionHarness(session: recognitionSession)
            defer { harness.tearDown() }

            let request = harness.enterStarting()
            harness.controller.continueStartRecording(startRequest: request)
            try await waitForAsyncCallbacks()
            try expect(recognitionSession.startCallCount == 1)

            harness.controller.cancel()
            try await waitForAsyncCallbacks()
            recognitionSession.completeNextStart(
                with: .failed(
                    RecognitionSessionFailure(
                        message: "late failure",
                        dismissAfter: 5,
                        stopAudioEngine: false,
                        recovery: nil
                    )
                )
            )
            try await waitForAsyncCallbacks()

            try expect(harness.controller.state.phase != .errored)
            try expect(
                !harness.presenter.events.contains {
                    if case .showError(let message, _, _) = $0 {
                        return message == "late failure"
                    }
                    return false
                }
            )
        }

        await runner.run("Recording UI responds while ASR preflight is pending") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession()
            session.completesPreparationImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try expect(harness.presenter.events.contains(.showInitial(compactStatusKey: nil)))
            try await waitForAsyncCallbacks()
            try expect(session.startCallCount == 0)
            harness.controller.stop()
            try expect(!harness.controller.isRecordingOrStarting)
            session.completePreparation()
            try await waitForAsyncCallbacks()
            try await waitForAsyncCallbacks()
            try expect(session.startCallCount == 1)
            try expect(session.stopCallCount == 1)
        }

        await runner.run("Release while ASR starts waits for readiness without reopening UI") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession()
            session.completesStartImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try expect(session.stopCallCount == 0)
            session.completeNextStart()
            try await waitForAsyncCallbacks()
            try expect(session.stopCallCount == 1)
            try expect(!harness.controller.isRecordingOrStarting)
        }

        await runner.run("Late final cannot interrupt next recording input startup") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(currentText: "old")
            session.completesStopImmediately = false
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.controller.stop()
            try await waitForAsyncCallbacks()
            harness.controller.start()
            session.completeStop()
            try expect(harness.controller.state.isStarting)
            try expect(harness.outputSink.deliveredTexts.isEmpty)
            try await waitForAsyncCallbacks()
            try expect(harness.controller.isRecording)
            harness.controller.cancel()
        }

        await runner.run("Recording session fixture delivers output side effect through fake sink") {
            let settings = RecordingSessionTestSettings()
            settings.apply(outputSinkCode: "fake")
            defer { settings.restore() }

            let harness = RecordingSessionHarness()
            defer { harness.tearDown() }
            harness.enterCapturing()

            harness.controller.execute(.deliverText("hello"))

            try expect(harness.outputSink.deliveredTexts == ["hello"])
        }
    }
}

private final class RecordingSessionTestSettings {
    private let defaults = UserDefaults.standard
    private let selectedLanguage: Any?
    private let recognitionEngine: Any?
    private let llmEnabled: Any?
    private let appleLiveInsertionEnabled: Any?
    private let lowerVolumeOnRecording: Any?
    private let textOutputSink: Any?

    init() {
        selectedLanguage = defaults.object(forKey: AppSettings.Keys.selectedLanguage)
        recognitionEngine = defaults.object(forKey: AppSettings.Keys.recognitionEngine)
        llmEnabled = defaults.object(forKey: AppSettings.Keys.llmEnabled)
        appleLiveInsertionEnabled = defaults.object(forKey: AppSettings.Keys.appleLiveInsertionEnabled)
        lowerVolumeOnRecording = defaults.object(forKey: AppSettings.Keys.lowerVolumeOnRecording)
        textOutputSink = defaults.object(forKey: AppSettings.Keys.textOutputSink)
    }

    func apply(outputSinkCode: String = "fake") {
        AppSettings.selectedLanguage = "en-US"
        AppSettings.recognitionEngine = ASREngineRegistry.appleCode
        AppSettings.llmEnabled = false
        AppSettings.appleLiveInsertionEnabled = false
        AppSettings.lowerVolumeOnRecording = false
        defaults.set(outputSinkCode, forKey: AppSettings.Keys.textOutputSink)
    }

    func restore() {
        restoreDefaultsObject(selectedLanguage, forKey: AppSettings.Keys.selectedLanguage)
        restoreDefaultsObject(recognitionEngine, forKey: AppSettings.Keys.recognitionEngine)
        restoreDefaultsObject(llmEnabled, forKey: AppSettings.Keys.llmEnabled)
        restoreDefaultsObject(appleLiveInsertionEnabled, forKey: AppSettings.Keys.appleLiveInsertionEnabled)
        restoreDefaultsObject(lowerVolumeOnRecording, forKey: AppSettings.Keys.lowerVolumeOnRecording)
        restoreDefaultsObject(textOutputSink, forKey: AppSettings.Keys.textOutputSink)
    }
}
