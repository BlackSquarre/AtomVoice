import Foundation
@testable import AtomVoiceCore

enum SherpaLifecycleCoordinatorTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("engine change from Sherpa to non-Sherpa releases model immediately when not recording") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: false)
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()
            harness.settings.engine = ASREngineRegistry.appleCode

            harness.postSettingsChange()

            try expect(harness.provider.releaseCount == 1)
        }

        await runner.run("engine change from Sherpa to non-Sherpa defers release while recording with route-reload session") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: true)
            harness.session.requiresModelReloadOnRouteChange = true
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()
            harness.settings.engine = ASREngineRegistry.appleCode

            harness.postSettingsChange()

            try expect(harness.provider.releaseCount == 0)
            harness.session.isRecording = false
            harness.coordinator.performPostRecordingCleanup()
            try expect(harness.provider.releaseCount == 1)
        }

        await runner.run("Sherpa preset change releases old model when not recording") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: false)
            harness.provider.hasSherpaEngineValue = true
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()
            harness.settings.presetID = "next-preset"

            harness.postSettingsChange()

            try expect(harness.provider.releaseCount == 1)
        }

        await runner.run("Sherpa preset change defers release while recording with route-reload session") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: true)
            harness.session.requiresModelReloadOnRouteChange = true
            harness.provider.hasSherpaEngineValue = true
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()
            harness.settings.presetID = "next-preset"

            harness.postSettingsChange()

            try expect(harness.provider.releaseCount == 0)
            harness.session.isRecording = false
            harness.coordinator.performPostRecordingCleanup()
            try expect(harness.provider.releaseCount == 1)
        }

        await runner.run("performPostRecordingCleanup releases pending model") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: true)
            harness.session.requiresModelReloadOnRouteChange = true
            harness.provider.hasSherpaEngineValue = true
            harness.coordinator.start()
            harness.settings.presetID = "next-preset"
            harness.postSettingsChange()

            harness.session.isRecording = false
            harness.coordinator.performPostRecordingCleanup()

            try expect(harness.provider.releaseCount == 1)
        }

        await runner.run("cancelAutoUnload clears scheduled work item") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: false)
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()
            harness.coordinator.performPostRecordingCleanup()
            let scheduled = try require(harness.scheduledWorkItems.first)

            harness.coordinator.cancelAutoUnload()
            scheduled.perform()

            try expect(harness.provider.releaseCount == 0)
        }

        await runner.run("scheduling auto-unload is no-op when current engine is not Sherpa") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.appleCode, isRecording: false)
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()

            harness.coordinator.performPostRecordingCleanup()

            try expect(harness.scheduledWorkItems.isEmpty)
        }

        await runner.run("scheduling auto-unload is no-op when sherpaAutoUnloadEnabled=false") {
            let harness = SherpaLifecycleHarness(engine: ASREngineRegistry.sherpaCode, isRecording: false)
            harness.settings.autoUnloadEnabled = false
            harness.provider.isSherpaModelLoadedValue = true
            harness.coordinator.start()

            harness.coordinator.performPostRecordingCleanup()

            try expect(harness.scheduledWorkItems.isEmpty)
        }
    }
}

private final class SherpaLifecycleHarness {
    let settings: FakeSherpaLifecycleSettings
    let provider = FakeSherpaEngineProvider()
    let session: FakeSherpaSessionInspector
    let notificationCenter = NotificationCenter()
    var scheduledDelays: [TimeInterval] = []
    var scheduledWorkItems: [DispatchWorkItem] = []
    lazy var coordinator = SherpaLifecycleCoordinator(
        registry: ASREngineRegistry.shared,
        provider: provider,
        sessionInspector: { [session] in session },
        settings: settings,
        notificationCenter: notificationCenter,
        notificationObject: nil,
        scheduleAfter: { [weak self] delay, workItem in
            self?.scheduledDelays.append(delay)
            self?.scheduledWorkItems.append(workItem)
        }
    )

    init(engine: String, isRecording: Bool) {
        settings = FakeSherpaLifecycleSettings(engine: engine)
        session = FakeSherpaSessionInspector(isRecording: isRecording)
    }

    func postSettingsChange() {
        notificationCenter.post(
            name: AppSettings.recognitionEngineSettingsDidChangeNotification,
            object: nil
        )
    }
}

private final class FakeSherpaSessionInspector: SherpaSessionInspector {
    var isRecording: Bool
    var requiresModelReloadOnRouteChange = false

    init(isRecording: Bool) {
        self.isRecording = isRecording
    }
}

private final class FakeSherpaLifecycleSettings: SherpaLifecycleSettingsProviding {
    var engine: String
    var presetID = "base-preset"
    var recognitionLanguage = "zh-CN"
    var provider = "coreml"
    var autoUnloadEnabled = true
    var idleMinutes = 15

    init(engine: String) {
        self.engine = engine
    }

    var normalizedRecognitionEngine: String { engine }
    var sherpaModelPresetID: String { presetID }
    var sherpaRecognitionLanguage: String { recognitionLanguage }
    var sherpaProvider: String { provider }
    var sherpaAutoUnloadEnabled: Bool { autoUnloadEnabled }
    var sherpaAutoUnloadIdleMinutes: Int { idleMinutes }
}

private final class FakeSherpaEngineProvider: ASREngineProviding {
    var hasSherpaEngineValue = false
    var isSherpaModelLoadedValue = false
    private(set) var releaseCount = 0

    var hasSherpaEngine: Bool { hasSherpaEngineValue }
    var isSherpaModelLoaded: Bool { isSherpaModelLoadedValue }

    func releaseSherpaEngine() {
        releaseCount += 1
        hasSherpaEngineValue = false
        isSherpaModelLoadedValue = false
    }

    func speechRecognizer() -> SpeechRecognizerController {
        fatalError("FakeSherpaEngineProvider does not create real engines")
    }

    func appleEngine() -> AppleSpeechASREngine {
        fatalError("FakeSherpaEngineProvider does not create real engines")
    }

    func sherpaEngine() -> SherpaOnnxASREngine {
        fatalError("FakeSherpaEngineProvider does not create real engines")
    }

    func volcengineEngine() -> VolcengineASREngine {
        fatalError("FakeSherpaEngineProvider does not create real engines")
    }

    func recognitionSession(for code: String, audioEngine: AudioEngineController) -> any RecognitionSession {
        fatalError("FakeSherpaEngineProvider does not create recognition sessions")
    }
}
