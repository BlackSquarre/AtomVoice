import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum RecordingSessionControllerTests {
    static func run(_ runner: inout TestRunner) async {
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

        await runner.run("Recording session ignores a late start failure after stop") {
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

            harness.controller.stop()
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
