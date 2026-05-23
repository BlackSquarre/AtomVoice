import Darwin
import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

@discardableResult
private func step(_ state: inout RecordingSessionState, _ event: RecordingEvent) -> [RecordingSideEffect] {
    let result = RecordingStateMachine.reduce(state, event)
    state = result.state
    return result.sideEffects
}

@main
struct ArchitectureTestRunner {
    static func main() async {
        var runner = TestRunner()

        await runner.run("Access kind maps card tags") {
            try expect(PermissionKind(permissionCardTag: 0) == .accessibility)
            try expect(PermissionKind(permissionCardTag: 1) == .microphone)
            try expect(PermissionKind(permissionCardTag: 2) == .speechRecognition)
            try expect(PermissionKind(permissionCardTag: -1) == nil)
            try expect(PermissionKind(permissionCardTag: 3) == nil)
        }

        await runner.run("Access gate ignores optional voice entitlement") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(service.hasRequiredPermissions(speechRequired: false))
        }

        await runner.run("Access gate requires voice entitlement when requested") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(!service.hasRequiredPermissions(speechRequired: true))

            access.statuses[.speechRecognition] = .granted
            try expect(service.hasRequiredPermissions(speechRequired: true))
        }

        await runner.run("Access gate requests undetermined capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("Access gate opens settings for denied capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 0)
            try expect(access.openedSettings == [.microphone])
        }

        await runner.run("Access gate requests undetermined dictation access") {
            let access = FakePermissionAccess(statuses: [.speechRecognition: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .speechRecognition)

            try expect(access.requestedSpeechRecognitionCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("Access gate opens assistive-control settings") {
            let access = FakePermissionAccess(statuses: [.accessibility: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .accessibility)

            try expect(access.openedSettings == [.accessibility])
        }

        await runner.run("ASR provider shares Apple stack instances") {
            let provider = ASREngineProvider()
            let speechRecognizer = provider.speechRecognizer()
            let appleEngine = provider.appleEngine()

            try expect(speechRecognizer === provider.speechRecognizer())
            try expect(appleEngine === provider.appleEngine())
            try expect(appleEngine.recognizer === speechRecognizer)
        }

        await runner.run("ASR provider releases local engine without model load") {
            let provider = ASREngineProvider()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let sherpaEngine = provider.sherpaEngine()
            try expect(provider.hasSherpaEngine)
            try expect(sherpaEngine === provider.sherpaEngine())
            try expect(!provider.isSherpaModelLoaded)

            provider.releaseSherpaEngine()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let recreatedSherpaEngine = provider.sherpaEngine()
            try expect(recreatedSherpaEngine !== sherpaEngine)
        }

        await runner.run("ASR provider shares cloud engine instance") {
            let provider = ASREngineProvider()
            let engine = provider.volcengineEngine()

            try expect(engine === provider.volcengineEngine())
        }

        await runner.run("ASR provider returns stable RecognitionSession wrappers") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let apple = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let appleAgain = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let sherpa = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            let doubao = provider.recognitionSession(for: VolcengineASRSettings.engineCode, audioEngine: audioEngine)

            try expect((apple as AnyObject) === (appleAgain as AnyObject))
            try expect(apple.code == ASREngineRegistry.appleCode)
            try expect(apple.preferredAudioFormat == nil)
            try expect(apple.supportsLiveInsertion)
            try expect(!apple.supportsServerFallback)
            try expect(sherpa.preferredAudioFormat == .voice16k)
            try expect(!sherpa.supportsLiveInsertion)
            try expect(doubao.preferredAudioFormat == .voice16k)
            try expect(doubao.supportsServerFallback)
        }

        await runner.run("RecognitionSession capabilities expose route-change reload needs") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let apple = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let sherpa = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            let doubao = provider.recognitionSession(for: VolcengineASRSettings.engineCode, audioEngine: audioEngine)

            try expect(!apple.requiresModelReloadOnRouteChange)
            try expect(sherpa.requiresModelReloadOnRouteChange)
            try expect(!doubao.requiresModelReloadOnRouteChange)
        }

        await runner.run("ASR provider rebuilds Sherpa RecognitionSession on release") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let session = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            provider.releaseSherpaEngine()
            let recreated = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)

            try expect((session as AnyObject) !== (recreated as AnyObject))
            try expect(!provider.isSherpaModelLoaded)
        }

        await runner.run("RecognitionSession callbacks separate generation from active recording") {
            var generation = 1
            var isRecording = true
            let callbacks = makeRecognitionSessionCallbacks(
                generationProvider: { generation },
                isRecordingProvider: { isRecording }
            )

            try expect(callbacks.isCurrent())
            try expect(callbacks.isRecordingCurrent())

            isRecording = false
            try expect(callbacks.isCurrent())
            try expect(!callbacks.isRecordingCurrent())

            generation = 2
            try expect(!callbacks.isCurrent())
            try expect(!callbacks.isRecordingCurrent())
        }

        await runner.run("Capsule animation selection preserves style compatibility") {
            let defaultSelection = CapsuleAnimationSelection.resolve(styleCode: nil)
            try expect(defaultSelection.style == .spotlight)
            try expect(defaultSelection.appliesSpotlightInset)
            try expect(defaultSelection.usesDynamicFrameCurve)
            try expect(approximatelyEqual(defaultSelection.frameAnimationDuration, 0.16))

            let noneSelection = CapsuleAnimationSelection.resolve(styleCode: "none")
            try expect(noneSelection.style == .none)
            try expect(!noneSelection.appliesSpotlightInset)
            try expect(!noneSelection.usesDynamicFrameCurve)
            try expect(approximatelyEqual(noneSelection.frameAnimationDuration, 0.2))

            let minimalSelection = CapsuleAnimationSelection.resolve(styleCode: "minimal")
            try expect(minimalSelection.style == .minimal)
            try expect(!minimalSelection.appliesSpotlightInset)
            try expect(!minimalSelection.usesDynamicFrameCurve)

            let unknownSelection = CapsuleAnimationSelection.resolve(styleCode: "future")
            try expect(unknownSelection.style == .spotlight)
            try expect(!unknownSelection.appliesSpotlightInset)
            try expect(!unknownSelection.usesDynamicFrameCurve)
        }

        await runner.run("Capsule animation factory creates no-animation strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "none")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleNoneAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }

        await runner.run("Capsule animation factory creates minimal strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "minimal")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleMinimalAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }

        await runner.run("Capsule animation factory creates spotlight inset strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "dynamicIsland")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleSpotlightAnimationStrategy)
            try expect(strategy.currentInset == CapsuleSpotlightAnimationStrategy.defaultInset)
        }

        await runner.run("Capsule animation factory preserves unknown-style no-inset fallback") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "future")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleSpotlightAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }

        await runner.run("Capsule spotlight motion resolves menu speed values") {
            let medium = CapsuleSpotlightMotion.resolve(speedCode: nil)
            try expect(approximatelyEqual(medium.inScale, 0.78))
            try expect(approximatelyEqual(medium.fadeIn, 0.055))
            try expect(approximatelyEqual(medium.scaleOut, 0.11))

            let slow = CapsuleSpotlightMotion.resolve(speedCode: "slow")
            try expect(approximatelyEqual(slow.inScale, 0.72))
            try expect(approximatelyEqual(slow.fadeOut, 0.14))
            try expect(approximatelyEqual(slow.scaleIn, 0.34))

            let fast = CapsuleSpotlightMotion.resolve(speedCode: "fast")
            try expect(approximatelyEqual(fast.inScale, 0.82))
            try expect(approximatelyEqual(fast.fadeIn, 0.04))
            try expect(approximatelyEqual(fast.scaleOut, 0.09))
        }

        await runner.run("Capsule spotlight keyframes keep entry and exit anchors") {
            let singleStart = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: true)
            try expect(approximatelyEqual(singleStart.width, 1.10))
            try expect(approximatelyEqual(singleStart.height, 0.76))

            let singleEnd = CapsuleSpotlightKeyframes.inScales(progress: 1, singleBounce: true)
            try expect(approximatelyEqual(singleEnd.width, 1.0))
            try expect(approximatelyEqual(singleEnd.height, 1.0))

            let highRefreshStart = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: false)
            try expect(approximatelyEqual(highRefreshStart.width, 1.16))
            try expect(approximatelyEqual(highRefreshStart.height, 0.68))

            let motion = CapsuleSpotlightMotion.resolve(speedCode: "medium")
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.outScale(progress: 0, singleBounce: true, motion: motion), 1.0))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.outScale(progress: 1, singleBounce: true, motion: motion), motion.outScale))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.frameInterval(singleBounce: true), 1.0 / 60.0))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.frameInterval(singleBounce: false), 1.0 / 120.0))
        }

        await runner.run("Capsule shimmer geometry derives band and sweep bounds") {
            let geometry = CapsuleShimmerGeometry.make(capsuleWidth: 200, capsuleHeight: 42)
            try expect(approximatelyEqual(geometry.bandWidth, 110))
            try expect(approximatelyEqual(geometry.clipFrame, CGRect(x: 0, y: 0, width: 200, height: 42)))
            try expect(approximatelyEqual(geometry.bandFrame, CGRect(x: -110, y: 0, width: 110, height: 42)))
            try expect(approximatelyEqual(geometry.startPositionX, -55))
            try expect(approximatelyEqual(geometry.endPositionX, 255))

            let minimumGeometry = CapsuleShimmerGeometry.make(capsuleWidth: 0, capsuleHeight: 42, minimumBandWidth: 1)
            try expect(approximatelyEqual(minimumGeometry.bandWidth, 1))
            try expect(approximatelyEqual(minimumGeometry.bandFrame, CGRect(x: -1, y: 0, width: 1, height: 42)))
        }

        await runner.run("Capsule spotlight strategies keep independent state") {
            let first = CapsuleSpotlightAnimationStrategy(currentInset: CapsuleSpotlightAnimationStrategy.defaultInset)
            let second = CapsuleSpotlightAnimationStrategy(currentInset: 0)

            first.springTimer = Timer(timeInterval: 10, repeats: false) { _ in }

            try expect(first.currentInset == CapsuleSpotlightAnimationStrategy.defaultInset)
            try expect(second.currentInset == 0)
            try expect(first.hasActiveTimer)
            try expect(!second.hasActiveTimer)

            first.stop()
            try expect(!first.hasActiveTimer)
            try expect(!second.hasActiveTimer)
        }

        await runner.run("Capsule shimmer strategy reapplies without leaking layers") {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 42))
            view.wantsLayer = true
            let strategy = CapsuleDefaultShimmerStrategy()
            let host = ShimmerHost(animationSurface: view, cornerRadius: 21, capsuleHeight: 42)

            strategy.apply(to: host)
            try expect(strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.count == 1)

            strategy.stop()
            try expect(!strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.isEmpty ?? true)

            strategy.apply(to: host)
            try expect(strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.count == 1)
            strategy.stop()
            try expect(view.layer?.sublayers?.isEmpty ?? true)
        }

        #if DEBUG_BUILD
        await runner.run("Capsule debug elapsed timer stops cleanly") {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 42))
            let strategy = CapsuleDebugElapsedTimerStrategy()

            strategy.start(in: CapsuleElapsedTimerHost(container: container))
            try expect(strategy.isRunning)
            try expect(!container.subviews.isEmpty)

            strategy.stop()
            try expect(!strategy.isRunning)
            try expect(container.subviews.isEmpty)
        }
        #endif

        await runner.run("ASR registry normalizes unknown engine codes") {
            let registry = ASREngineRegistry(descriptors: [.sherpaOnnx, .apple, .volcengine])

            try expect(registry.normalizedCode(for: nil) == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: "missing") == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: ASREngineRegistry.sherpaCode) == ASREngineRegistry.sherpaCode)
        }

        await runner.run("ASR registry keeps cloud boundary explicit") {
            let registry = ASREngineRegistry.shared

            try expect(registry.isCloud(VolcengineASRSettings.engineCode))
            try expect(!registry.isCloud(ASREngineRegistry.appleCode))
            try expect(!registry.isCloud(ASREngineRegistry.sherpaCode))
            try expect(registry.descriptor(for: VolcengineASRSettings.engineCode)?.requiresCredential == true)
            try expect(registry.descriptor(for: ASREngineRegistry.sherpaCode)?.isOffline == true)
        }

        await runner.run("App settings posts precise recognition engine notifications") {
            let defaults = UserDefaults.standard
            let oldEngine = defaults.object(forKey: AppSettings.Keys.recognitionEngine)
            let oldProvider = defaults.object(forKey: AppSettings.Keys.sherpaProvider)
            let unrelatedKey = "AtomVoiceArchitectureTests.unrelatedDefaultsKey"
            defer {
                restoreDefaultsObject(oldEngine, forKey: AppSettings.Keys.recognitionEngine)
                restoreDefaultsObject(oldProvider, forKey: AppSettings.Keys.sherpaProvider)
                defaults.removeObject(forKey: unrelatedKey)
            }

            var changedKeys: [String] = []
            let token = NotificationCenter.default.addObserver(
                forName: AppSettings.recognitionEngineSettingsDidChangeNotification,
                object: defaults,
                queue: nil
            ) { notification in
                if let key = notification.userInfo?[AppSettings.recognitionEngineSettingsChangedKey] as? String {
                    changedKeys.append(key)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            AppSettings.recognitionEngine = ASREngineRegistry.appleCode
            changedKeys.removeAll()

            defaults.set("unrelated", forKey: unrelatedKey)
            AppSettings.recognitionEngine = ASREngineRegistry.sherpaCode
            AppSettings.recognitionEngine = ASREngineRegistry.sherpaCode
            AppSettings.sherpaProvider = "cpu"

            try expect(changedKeys == [AppSettings.Keys.recognitionEngine, AppSettings.Keys.sherpaProvider])
        }

        await runner.run("Recording session state covers start and cancel transitions") {
            var state = RecordingSessionState()

            step(&state, .triggerPressed(deferCapsulePresentation: true))
            let firstRequest = state.startRequestGeneration
            try expect(state.isStarting)
            try expect(state.isRecordingOrStarting)
            try expect(state.deferredCapsule.isDeferred)
            let duplicateStartEffects = step(&state, .triggerPressed(deferCapsulePresentation: false))
            try expect(duplicateStartEffects.isEmpty)
            try expect(state.startRequestGeneration == firstRequest)
            try expect(state.acceptsStartRequest(firstRequest))

            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )
            let generation = state.recordingGeneration
            try expect(generation == 1)
            try expect(state.isRecording)
            try expect(!state.isStarting)
            try expect(state.currentRecordingEngine == ASREngineRegistry.appleCode)

            state.liveInsertion.isActive = true
            state.liveInsertion.committedText = "hello"
            step(&state, .cancelRequested)

            try expect(!state.isRecordingOrStarting)
            try expect(state.recordingGeneration == 2)
            try expect(!state.deferredCapsule.isDeferred)
        }

        await runner.run("Recording session state clears refining and Doubao wait") {
            var state = RecordingSessionState()

            step(&state, .refiningStarted(text: "pending"))
            try expect(state.isRefining)
            try expect(state.pendingRefinementText == "pending")
            step(&state, .refiningFinished)
            try expect(!state.isRefining)
            try expect(state.pendingRefinementText == nil)

            step(&state, .doubaoFinalWaitStarted)
            try expect(state.isWaitingForDoubaoFinalResult)
            state.liveInsertion.isActive = true
            state.liveInsertion.committedText = "live"
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )
            step(&state, .cancelRequested)

            try expect(!state.isWaitingForDoubaoFinalResult)
            try expect(!state.liveInsertion.isActive)
            try expect(state.liveInsertion.committedText.isEmpty)
        }

        await runner.run("Recording state machine starts idle requests") {
            let result = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: true)
            )

            try expect(result.state.phase == .starting)
            try expect(result.state.startRequestGeneration == 1)
            try expect(result.state.deferredCapsule.isDeferred)
            try expect(result.sideEffects == [.waitForInputReady(request: 1)])
        }

        await runner.run("Recording state machine ignores duplicate start while starting") {
            let first = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let duplicate = RecordingStateMachine.reduce(
                first.state,
                .triggerPressed(deferCapsulePresentation: false)
            )

            try expect(duplicate.state.startRequestGeneration == 1)
            try expect(duplicate.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine validates ready input preflight") {
            let start = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let ready = RecordingStateMachine.reduce(
                start.state,
                .inputPreflightCompleted(request: 1, ready: true)
            )

            try expect(ready.state.phase == .starting)
            try expect(ready.sideEffects == [.validateStart(request: 1)])
        }

        await runner.run("Recording state machine errors failed input preflight") {
            let start = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let failed = RecordingStateMachine.reduce(
                start.state,
                .inputPreflightCompleted(request: 1, ready: false)
            )

            try expect(failed.state.phase == .errored)
            try expect(failed.sideEffects == [
                .showCapsule(.initial, ensurePanel: true),
                .showCapsule(.errorKey(messageKey: "error.noInputDevice", dismissAfter: 5), ensurePanel: true),
            ])
        }

        await runner.run("Recording state machine ignores stale preflight") {
            let start = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let stale = RecordingStateMachine.reduce(
                start.state,
                .inputPreflightCompleted(request: 99, ready: true)
            )

            try expect(stale.state.phase == .starting)
            try expect(stale.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine requests external Sherpa download") {
            let start = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let missing = RecordingStateMachine.reduce(
                start.state,
                .externalModelDownloadRequired(redownload: false)
            )

            try expect(missing.state.phase == .idle)
            try expect(missing.sideEffects == [.requestSherpaModelDownload(redownload: false, delay: 0)])
        }

        await runner.run("Recording state machine starts capturing and side effects") {
            let start = RecordingStateMachine.reduce(
                RecordingSessionState(),
                .triggerPressed(deferCapsulePresentation: false)
            )
            let capturing = RecordingStateMachine.reduce(
                start.state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: true
                )
            )

            try expect(capturing.state.phase == .capturing)
            try expect(capturing.state.recordingGeneration == 1)
            try expect(capturing.state.currentRecordingEngine == ASREngineRegistry.appleCode)
            try expect(capturing.sideEffects.contains(.cancelLLM))
            try expect(capturing.sideEffects.contains(.notifyRecording(true)))
            try expect(capturing.sideEffects.contains(.lowerVolume))
            try expect(capturing.sideEffects.contains(.startSession(generation: 1)))
        }

        await runner.run("Recording state machine delivers pending Doubao and refinement text on new start") {
            var state = RecordingSessionState()
            step(&state, .refiningStarted(text: "old llm"))
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(&state, .doubaoFinalWaitStarted)

            let result = RecordingStateMachine.reduce(
                state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: "cloud text",
                    pendingRefinementText: "old llm",
                    lowerVolume: false
                )
            )

            try expect(!result.state.isWaitingForDoubaoFinalResult)
            try expect(!result.state.isRefining)
            try expect(result.sideEffects.contains(.deliverText("cloud text")))
            try expect(result.sideEffects.contains(.deliverText("old llm")))
            try expect(result.sideEffects.contains(.notifyRefining(false)))
        }

        await runner.run("Recording state machine stops normal recording") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )
            let generation = state.recordingGeneration

            let stopped = RecordingStateMachine.reduce(state, .triggerReleased)

            try expect(stopped.state.phase == .stopping)
            try expect(stopped.sideEffects.contains(.stopSession(generation: generation, immediate: false, appending: nil)))
            try expect(stopped.sideEffects.contains(.notifyRecording(false)))
            try expect(stopped.sideEffects.contains(.restoreVolume))
        }

        await runner.run("Recording state machine stops immediate with punctuation") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )
            let generation = state.recordingGeneration

            let stopped = RecordingStateMachine.reduce(state, .immediateStop(appending: "?"))

            try expect(stopped.state.phase == .stopping)
            try expect(stopped.sideEffects.contains(.stopSession(generation: generation, immediate: true, appending: "?")))
        }

        await runner.run("Recording state machine cancels capturing") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )
            state.liveInsertion.isActive = true
            state.pendingRefinementText = "pending"

            let cancelled = RecordingStateMachine.reduce(state, .cancelRequested)

            try expect(cancelled.state.phase == .cancelled)
            try expect(cancelled.state.recordingGeneration == 2)
            try expect(!cancelled.state.liveInsertion.isActive)
            try expect(cancelled.sideEffects.contains(.cancelSession(stopAudioEngine: true)))
            try expect(cancelled.sideEffects.contains(.dismissCapsule))
            try expect(cancelled.sideEffects.contains(.notifySessionDidEnd))
        }

        await runner.run("Recording state machine lightly cancels pending start") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: true))
            let request = state.startRequestGeneration
            state.deferredCapsule.pendingPresentation = .recording
            state.deferredCapsule.recognizedText = "pending"

            let cancelled = RecordingStateMachine.reduce(state, .cancelRequested)

            try expect(cancelled.state.phase == .cancelled)
            try expect(cancelled.state.startRequestGeneration == request + 1)
            try expect(!cancelled.state.deferredCapsule.isDeferred)
            try expect(cancelled.sideEffects.isEmpty)
            try expect(!cancelled.sideEffects.contains(.notifySessionDidEnd))
            try expect(!cancelled.sideEffects.contains(.restoreVolume))
            try expect(!cancelled.sideEffects.contains(.cancelLLM))
        }

        await runner.run("Recording state machine handles audio route failure") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let failed = RecordingStateMachine.reduce(state, .audioRouteRecoveryFailed)

            try expect(failed.state.phase == .errored)
            try expect(failed.sideEffects.contains(.abandonAudioRouteRecovery))
            try expect(failed.sideEffects.contains(.cancelSession(stopAudioEngine: false)))
            try expect(failed.sideEffects.contains(.notifySessionDidEnd))
        }

        await runner.run("Recording state machine tracks Doubao final wait") {
            var state = RecordingSessionState()
            let waiting = RecordingStateMachine.reduce(state, .doubaoFinalWaitStarted)
            state = waiting.state
            try expect(state.isWaitingForDoubaoFinalResult)

            let ended = RecordingStateMachine.reduce(state, .doubaoFinalWaitEnded)
            try expect(!ended.state.isWaitingForDoubaoFinalResult)
        }

        await runner.run("Recording state machine switches fallback engine") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: VolcengineASRSettings.engineCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let fallback = RecordingStateMachine.reduce(state, .fallbackStarted(engine: ASREngineRegistry.appleCode))

            try expect(fallback.state.currentRecordingEngine == ASREngineRegistry.appleCode)
            try expect(fallback.sideEffects == [
                .showCapsule(.progressKey(messageKey: "menu.recognitionEngine.apple", hidesWaveform: true), ensurePanel: false)
            ])
        }

        await runner.run("Recording state machine stores deferred partial text") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: true))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let partial = RecordingStateMachine.reduce(state, .asrPartial(text: "hello", isFinal: false))

            try expect(partial.state.deferredCapsule.recognizedText == "hello")
            try expect(partial.sideEffects.contains(.noteASRText("hello")))
            try expect(!partial.sideEffects.contains(.updateCapsuleText("hello")))
        }

        await runner.run("Recording state machine updates visible partial text") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let partial = RecordingStateMachine.reduce(state, .asrPartial(text: "hello", isFinal: false))

            try expect(partial.sideEffects.contains(.updateCapsuleText("hello")))
            try expect(partial.sideEffects.contains(.noteASRText("hello")))
        }

        await runner.run("Recording state machine controls text output activation") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let activated = RecordingStateMachine.reduce(state, .textOutputActivated(liveInsertion: true))
            try expect(activated.state.textOutputActivated)
            try expect(activated.state.liveInsertion.isActive)

            let duplicate = RecordingStateMachine.reduce(activated.state, .textOutputActivated(liveInsertion: false))
            try expect(duplicate.state.liveInsertion.isActive)
            try expect(duplicate.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine stores deferred capsule presentation") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: true))

            let progress = RecordingStateMachine.reduce(
                state,
                .capsulePresentationRequested(.progress(text: "loading", hidesWaveform: true))
            )

            try expect(progress.state.deferredCapsule.pendingPresentation == .progress(text: "loading", hidesWaveform: true))
            try expect(progress.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine emits visible capsule presentation") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))

            let progress = RecordingStateMachine.reduce(
                state,
                .capsulePresentationRequested(.progress(text: "loading", hidesWaveform: true))
            )

            try expect(progress.sideEffects == [.showCapsule(.progress(text: "loading", hidesWaveform: true), ensurePanel: false)])
        }

        await runner.run("Recording state machine tracks shimmer in deferred mode") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: true))

            let shimmer = RecordingStateMachine.reduce(state, .shimmerChanged(true))

            try expect(shimmer.state.deferredCapsule.pendingShimmer)
            try expect(shimmer.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine observes live insertion latest only while active") {
            var state = RecordingSessionState()
            state.liveInsertion.latestText = "old"

            let inactive = RecordingStateMachine.reduce(state, .liveInsertionLatestObserved(text: "new"))
            try expect(inactive.state.liveInsertion.latestText == "old")

            state.liveInsertion.isActive = true
            state.liveInsertion.committedText = "committed"
            let active = RecordingStateMachine.reduce(state, .liveInsertionLatestObserved(text: "new"))
            try expect(active.state.liveInsertion.latestText == "new")
            try expect(active.state.liveInsertion.committedText == "committed")
        }

        await runner.run("Recording state machine observes latest text while paste is in flight") {
            var state = RecordingSessionState()
            state.liveInsertion.isActive = true
            state.liveInsertion.latestText = "old"
            state.liveInsertion.pasteInFlight = true

            let observed = RecordingStateMachine.reduce(state, .liveInsertionLatestObserved(text: "newer partial"))

            try expect(observed.state.liveInsertion.latestText == "newer partial")
            try expect(observed.state.liveInsertion.pasteInFlight)
            try expect(observed.sideEffects.isEmpty)
        }

        await runner.run("Recording state machine commits live insertion segment") {
            var state = RecordingSessionState()
            state.liveInsertion.latestText = "hello"

            let committed = RecordingStateMachine.reduce(
                state,
                .liveInsertionCommitted(segment: "hello.", latestText: "hello.")
            )

            try expect(committed.state.liveInsertion.committedText == "hello.")
            try expect(committed.state.liveInsertion.latestText == "hello.")
            try expect(committed.state.liveInsertion.pasteInFlight)
            try expect(committed.sideEffects == [.deliverText("hello.")])
        }

        await runner.run("Recording state machine clears live insertion after paste") {
            var state = RecordingSessionState()
            state.liveInsertion.pasteInFlight = true

            let finished = RecordingStateMachine.reduce(state, .liveInsertionCommitFinished)

            try expect(!finished.state.liveInsertion.pasteInFlight)
        }

        await runner.run("Recording state machine records LLM result") {
            var state = RecordingSessionState()
            step(&state, .refiningStarted(text: "draft"))

            let result = RecordingStateMachine.reduce(state, .llmResult(text: "polished"))

            try expect(result.state.phase == .idle)
            try expect(!result.state.isRefining)
            try expect(result.sideEffects.contains(.notifyRefining(false)))
            try expect(result.sideEffects.contains(.deliverText("polished")))
        }

        await runner.run("Recording state machine records LLM error") {
            var state = RecordingSessionState()
            step(&state, .refiningStarted(text: "draft"))

            let result = RecordingStateMachine.reduce(state, .llmError(message: "bad"))

            try expect(result.state.phase == .errored)
            try expect(!result.state.isRefining)
            try expect(result.sideEffects.contains(.showCapsule(.error(message: "bad", dismissAfter: 3), ensurePanel: false)))
        }

        await runner.run("Recording session presentation reveal emits ordered events") {
            try expect(
                RecordingSessionPresentationEvent.revealEvents(
                    for: .none,
                    isRecording: false,
                    compactStatusKey: "capsule.streaming.typing"
                ).isEmpty
            )
            try expect(
                RecordingSessionPresentationEvent.revealEvents(
                    for: .initial,
                    isRecording: true,
                    compactStatusKey: "capsule.streaming.typing"
                ) == [.showInitial(compactStatusKey: "capsule.streaming.typing")]
            )
            try expect(
                RecordingSessionPresentationEvent.revealEvents(
                    for: .recording,
                    isRecording: true,
                    compactStatusKey: nil
                ) == [.showInitial(compactStatusKey: nil), .showRecording]
            )
            try expect(
                RecordingSessionPresentationEvent.revealEvents(
                    for: .error(message: "failed", dismissAfter: 2),
                    isRecording: true,
                    compactStatusKey: nil
                ) == [.showError(message: "failed", dismissAfter: 2, ensurePanel: true)]
            )
        }

        await runner.run("Keychain upsert updates, adds, and recovers duplicate add") {
            var operations: [String] = []

            let updated = KeychainStore.upsertResult(
                updateStatus: errSecSuccess,
                addItem: {
                    operations.append("add")
                    return errSecSuccess
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(updated)
            try expect(operations.isEmpty)

            operations.removeAll()
            let added = KeychainStore.upsertResult(
                updateStatus: errSecItemNotFound,
                addItem: {
                    operations.append("add")
                    return errSecSuccess
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(added)
            try expect(operations == ["add"])

            operations.removeAll()
            let recoveredDuplicate = KeychainStore.upsertResult(
                updateStatus: errSecItemNotFound,
                addItem: {
                    operations.append("add")
                    return errSecDuplicateItem
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(recoveredDuplicate)
            try expect(operations == ["add", "updateAfterDuplicate"])
        }

        await runner.run("ASR silence monitor fires when no text arrives within duration") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = false
            AppSettings.silenceDuration = 0.7

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            monitor.stop()

            try expect(timeoutCount >= 1)
        }

        await runner.run("ASR silence monitor keeps alive when text keeps growing") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = false
            AppSettings.silenceDuration = 0.5

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            // 每 200ms 喂一次新文本，silenceDuration=0.5s 永远不会到
            for i in 1...10 {
                try await Task.sleep(nanoseconds: 200_000_000)
                monitor.noteText("partial \(i)")
            }
            monitor.stop()

            try expect(timeoutCount == 0)
        }

        await runner.run("ASR silence monitor respects manual stop setting") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = true
            AppSettings.silenceDuration = 0.3

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            monitor.stop()

            try expect(timeoutCount == 0)
        }

        await runner.run("Text processor registry stops at first handler") {
            let first = FakeTextProcessor(id: "first", output: nil)
            let second = FakeTextProcessor(id: "second", output: "handled")
            let third = FakeTextProcessor(id: "third", output: "late")
            let registry = TextPostProcessorRegistry(processors: [first, second, third])
            let context = TextProcessingContext(
                engineCode: ASREngineRegistry.appleCode,
                language: "en-US",
                isImmediateFinish: false
            )

            try expect(registry.run("raw", context: context) == "handled")
            try expect(first.callCount == 1)
            try expect(second.callCount == 1)
            try expect(third.callCount == 0)
        }

        await runner.run("Recognition finalizer delivers processed paste text") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])

            harness.finish("hello")

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(processor.lastContext?.isImmediateFinish == false)
        }

        await runner.run("Recognition finalizer replaces streaming text when punctuation changes") {
            let stream = FakeTextStreamSession()
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])

            harness.finish("hello", streamSession: stream)

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
            try expect(stream.finalizedReplacements == ["hello."])
            try expect(stream.cancelCount == 0)
            try expect(harness.clearedStreamCount == 1)
        }

        await runner.run("Recognition finalizer appends immediate punctuation without LLM") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextResult = "HELLO"

            harness.finish("hello", mode: .immediate(appending: "?"))

            try expect(harness.refiner.requests.isEmpty)
            try expect(harness.sink.deliveredTexts == ["hello?"])
            try expect(processor.lastContext?.isImmediateFinish == true)
        }

        await runner.run("Recognition finalizer runs LLM for paste output") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextProgress = "pol"
            harness.refiner.nextResult = "polished."

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "update:pol", "update:polished.", "dismiss"])
            try expect(harness.sink.deliveredTexts == ["polished."])
        }

        await runner.run("Recognition finalizer delivers processed text when LLM fails") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextError = "LLM failed"

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "error:LLM failed:3.0"])
        }

        await runner.run("Recognition finalizer handles empty text error fallback") {
            let harness = RecognitionFinalizerHarness()
            let stream = FakeTextStreamSession()

            harness.finish("", errorMessage: "No speech", streamSession: stream)

            try expect(stream.cancelCount == 1)
            try expect(harness.clearedStreamCount == 1)
            try expect(harness.presenter.events == ["error:No speech:5.0"])
            try expect(harness.sink.deliveredTexts.isEmpty)
        }

        await runner.run("Recognition finalizer injects live insertion remainder") {
            let harness = RecognitionFinalizerHarness()

            harness.finish(
                "Hello world again",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello world")
            )

            try expect(harness.sink.deliveredTexts == ["again"])
        }

        await runner.run("Recognition finalizer keeps LLM for streaming after live insertion") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextResult = "world polished"
            let stream = FakeTextStreamSession()

            harness.finish(
                "Hello world",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello"),
                streamSession: stream
            )
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["world"])
            try expect(stream.finalizedReplacements == ["world polished"])
            try expect(harness.clearedStreamCount == 1)
        }

        await runner.run("Recognition finalizer computes live insertion remainder") {
            let harness = RecognitionFinalizerHarness()

            try expect(
                harness.remainingText(
                    "Hello world again",
                    committedText: "Hello world"
                ) == "again"
            )
            try expect(
                harness.remainingText(
                    "Hello world again",
                    committedText: "Hello world "
                ) == "again"
            )
            try expect(
                harness.remainingText(
                    "Hello brave world",
                    committedText: "Hello basic"
                ) == "brave world"
            )
            try expect(
                harness.remainingText(
                    "Unrelated final",
                    committedText: "Hello"
                ) == "Unrelated final"
            )
        }

        await runner.run("Cloud fallback text merge removes overlap") {
            let merged = DoubaoFallbackCoordinator.combinedText(
                prefix: "hello world",
                cachedText: "world from cache",
                liveText: "cache again"
            )

            try expect(merged == "hello world from cache again")
        }

        await runner.run("Cloud fallback text merge handles spacing and CJK") {
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "hello",
                    cachedText: "there",
                    liveText: ""
                ) == "hello there"
            )
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "你好",
                    cachedText: "世界",
                    liveText: ""
                ) == "你好世界"
            )
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "hello.",
                    cachedText: "world",
                    liveText: ""
                ) == "hello. world"
            )
        }

        await runner.run("Apple speech rolling merge inserts Latin spacing") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "this is a test"
            )

            try expect(merged == "hello world this is a test")
        }

        await runner.run("Apple speech rolling merge removes overlap") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "world again"
            )

            try expect(merged == "hello world again")
        }

        await runner.run("Apple speech rolling merge keeps CJK tight") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "你好世界",
                segment: "继续说"
            )

            try expect(merged == "你好世界继续说")
        }

        await runner.run("Punctuation processor adds language-aware endings") {
            try expect(PunctuationProcessor.process("你好世界", language: "zh-CN") == "你好世界。")
            try expect(PunctuationProcessor.process("你好吗", language: "zh-CN") == "你好吗？")
            try expect(PunctuationProcessor.process("what time is it", language: "en-US") == "what time is it?")
            try expect(PunctuationProcessor.process("wow this works", language: "en-US") == "wow this works!")
            try expect(PunctuationProcessor.process("hello.", language: "en-US") == "hello.")
        }

        await runner.run("Punctuation detector exposes CJK and Latin decisions") {
            try expect(PunctuationProcessor.detectCJKPunctuation("可以吗", language: "zh-CN") == "？")
            try expect(PunctuationProcessor.detectCJKPunctuation("太好了", language: "zh-CN") == "！")
            try expect(PunctuationProcessor.detectCJKPunctuation("文件等等", language: "zh-CN") == "……")
            try expect(PunctuationProcessor.detectLatinPunctuation("is this ready", language: "en-US") == "?")
            try expect(PunctuationProcessor.detectLatinPunctuation("this is perfect", language: "en-US") == "!")
            try expect(PunctuationProcessor.detectLatinPunctuation("this is ready", language: "en-US") == ".")
        }

        await runner.run("Apple live insertion adapter commits only stable segments") {
            let adapter = AppleLiveInsertionAdapter()

            let first = try require(
                adapter.nextCommitDecision(
                    latestPartial: "hello. wor",
                    committedText: "",
                    isFinal: false
                )
            )
            try expect(first == AppleLiveSegmentDecision(segment: "hello. ", updatedCommittedText: "hello. "))

            try expect(
                adapter.nextCommitDecision(
                    latestPartial: "hello. wo",
                    committedText: "",
                    isFinal: false
                ) == nil
            )

            let final = try require(
                adapter.nextCommitDecision(
                    latestPartial: "hello.",
                    committedText: "",
                    isFinal: true
                )
            )
            try expect(final == AppleLiveSegmentDecision(segment: "hello.", updatedCommittedText: "hello."))

            try expect(
                adapter.nextCommitDecision(
                    latestPartial: "hello world. next",
                    committedText: "hello wor",
                    isFinal: false
                ) == nil
            )
        }

        await runner.run("Update checker parses versions and compares pre-release") {
            let checker = UpdateChecker.shared
            let parsed = checker.parseVersion("v0.10.4-Beta-2")

            try expect(parsed.numbers == [0, 10, 4])
            try expect(parsed.preRelease == ["beta", "2"])
            try expect(checker.isNewer("0.10.5", than: "0.10.4"))
            try expect(checker.isNewer("0.10.4", than: "0.10.4-Beta-2"))
            try expect(checker.isNewer("0.10.4-Beta-3", than: "0.10.4-Beta-2"))
            try expect(!checker.isNewer("0.10.4-Beta-2", than: "0.10.4"))
            try expect(checker.comparePreRelease(["beta", "10"], ["beta", "2"]) == .orderedDescending)
            try expect(checker.comparePreRelease(["beta"], ["beta", "1"]) == .orderedAscending)
        }

        await runner.run("Update checker extracts checksum by asset name") {
            let checker = UpdateChecker.shared
            let listing = """
            0123456789ABCDEF  AtomVoice-0.10.4.zip
            abcdef0123456789 *AtomVoice-0.10.4-Debug.zip
            """

            try expect(checker.expectedChecksum(in: listing, assetName: "AtomVoice-0.10.4.zip") == "0123456789abcdef")
            try expect(checker.expectedChecksum(in: listing, assetName: "AtomVoice-0.10.4-Debug.zip") == "abcdef0123456789")
            try expect(checker.expectedChecksum(in: listing, assetName: "missing.zip") == nil)
        }

        await runner.run("LLM refiner builds provider endpoints") {
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1/chat") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1/chat/completions/") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.anthropic.com/v1") == "https://api.anthropic.com/v1/messages")
            try expect(LLMRefiner.buildURL(base: "https://api.anthropic.com/v1/messages") == "https://api.anthropic.com/v1/messages")
            try expect(LLMRefiner.buildCompletionsURL(base: "https://example.com/api/") == "https://example.com/api/chat/completions")
        }

        await runner.run("LLM refiner finds trailing UTF-8 boundary") {
            let complete = Data("hello你".utf8)
            let cjkBytes = Array("你".utf8)
            let splitCJK = Data("hello".utf8) + Data(cjkBytes.prefix(2))
            let emojiBytes = Array("🙂".utf8)
            let splitEmoji = Data("hello".utf8) + Data(emojiBytes.prefix(3))

            try expect(LLMRefiner.validUTF8PrefixLength(complete) == complete.count)
            try expect(LLMRefiner.validUTF8PrefixLength(splitCJK) == 5)
            try expect(LLMRefiner.validUTF8PrefixLength(splitEmoji) == 5)
            try expect(LLMRefiner.validUTF8PrefixLength(Data([0xE4])) == 0)
        }

        await runner.run("Headphone HID trusts non-keyboard USB consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x1234,
                productID: 0x5678,
                locationID: 1,
                manufacturer: "MOONDROP",
                product: "MAY Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(decision.isTrusted)
        }

        await runner.run("Headphone HID rejects keyboard consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Bluetooth",
                vendorID: 0x05AC,
                productID: 0x029C,
                locationID: 1,
                manufacturer: "Apple Inc.",
                product: "Magic Keyboard",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    ),
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.genericDesktopPage,
                        usage: HeadphoneHIDSourceClassifier.keyboardUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-usage")
        }

        await runner.run("Headphone HID rejects unknown source by default") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: nil,
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: nil,
                product: nil,
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "unsupported-transport")
        }

        await runner.run("Headphone HID rejects AirPods names") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Bluetooth",
                vendorID: 0x05AC,
                productID: 0x1234,
                locationID: 1,
                manufacturer: "Apple Inc.",
                product: "Lingru's AirPods Pro",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "airpods-unsupported")
        }

        await runner.run("Headphone HID rejects keyboard property hints") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x1234,
                productID: 0x5678,
                locationID: 1,
                manufacturer: "Generic",
                product: "Consumer Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: true,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-property")
        }

        await runner.run("Headphone HID rejects ambiguous USB receiver names") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x046D,
                productID: 0xC548,
                locationID: 1,
                manufacturer: "Logitech",
                product: "USB Receiver",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-name")
        }

        await runner.run("Headphone HID trusts named audio headset control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Audio",
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: "Apple",
                product: "Headset",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(decision.isTrusted)
        }

        await runner.run("Headphone HID rejects generic audio consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Audio",
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: "Generic",
                product: "Consumer Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "unsupported-transport")
        }

        await runner.run("Model manifest discovers nested files offline") {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let exp = root.appendingPathComponent("exp", isDirectory: true)
            let lang = root.appendingPathComponent("data/lang_char", isDirectory: true)
            try FileManager.default.createDirectory(at: exp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: lang, withIntermediateDirectories: true)

            try writeDummyFile(exp.appendingPathComponent("streaming-encoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-encoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-joiner-int8.onnx"))
            try writeDummyFile(lang.appendingPathComponent("tokens.txt"))

            let manifest = try require(ModelManifest.discover(in: root), "manifest should be discovered")

            try expect(manifest.encoder == "exp/streaming-encoder-int8.onnx")
            try expect(manifest.decoder == "exp/streaming-decoder.onnx")
            try expect(manifest.joiner == "exp/streaming-joiner-int8.onnx")
            try expect(manifest.tokens == "data/lang_char/tokens.txt")
            try expect(manifest.isComplete(in: root))
        }

        await runner.run("Sherpa preload drains buffered audio in order") {
            let coordinator = SherpaPreloadCoordinator()
            let first = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.1))
            let second = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.2))

            coordinator.begin()
            try expect(coordinator.appendIfActive(first) { $0 })
            try expect(coordinator.appendIfActive(second) { $0 })
            try await waitForAsyncCallbacks()

            var drained: [AVAudioPCMBuffer] = []
            var completed = false
            coordinator.drain(
                accept: { drained.append($0) },
                onComplete: { completed = true }
            )
            try await waitForAsyncCallbacks()

            try expect(completed)
            try expect(drained.count == 2)
            try expect(drained[0] === first)
            try expect(drained[1] === second)
            try expect(!coordinator.appendIfActive(first) { $0 })
        }

        await runner.run("Audio router unregisters native consumers") {
            let router = AudioRouter()
            let buffer = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 32), "buffer should be created")
            var firstCount = 0
            var secondCount = 0

            let firstID = router.register(format: nil) { received in
                if received === buffer { firstCount += 1 }
            }
            let secondID = router.register(format: nil) { received in
                if received === buffer { secondCount += 1 }
            }

            router.receive(buffer)
            router.unregister(firstID)
            router.receive(buffer)

            try expect(firstCount == 1)
            try expect(secondCount == 2)
            try expect(secondID != firstID)
        }

        await runner.run("Audio router shares converted buffer for matching target consumers") {
            let router = AudioRouter()
            let input = try require(makePCMBuffer(sampleRate: 48_000, frameLength: 480), "buffer should be created")
            var firstBuffer: AVAudioPCMBuffer?
            var secondBuffer: AVAudioPCMBuffer?

            _ = router.register(format: .voice16k) { firstBuffer = $0 }
            _ = router.register(format: .voice16k) { secondBuffer = $0 }

            router.receive(input)

            try expect(firstBuffer != nil)
            try expect(firstBuffer === secondBuffer)
            try expect(firstBuffer?.format.sampleRate == 16_000)
            try expect(firstBuffer?.format.channelCount == 1)
        }

        await runner.run("Recognition finalizer ignores LLM results from old generation") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            
            harness.refiner.delayCompletion = true
            harness.generation = 10
            
            harness.finish("hello")
            
            // Verify refiner is called and refining state is true
            try expect(harness.refiner.requests == ["hello"])
            try expect(harness.isRefining == true)
            try expect(harness.presenter.events == ["refining"])
            
            // Advance generation to 11 (simulating cancellation/restarting a session)
            harness.generation = 11
            
            // Fire the delayed completion callbacks for generation 10
            harness.refiner.pendingOnProgress?("progress")
            
            // Trigger completion on main queue since completion executes inside DispatchQueue.main.async block
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            // Verify that the old generation's progress/completion results were completely ignored!
            // No new presenter events and no text delivered to sink!
            try expect(harness.presenter.events == ["refining"]) // remains unchanged, no "update:progress" or "update:polished"
            try expect(harness.sink.deliveredTexts.isEmpty)
        }

        await runner.run("Recognition finalizer updates refining state correctly") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.delayCompletion = true
            
            harness.generation = 1
            harness.finish("hello")
            
            try expect(harness.isRefining == true)
            
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            try expect(harness.isRefining == false)
            try expect(harness.sink.deliveredTexts == ["polished"])
        }

        runner.finish()
    }
}

private struct TestRunner {
    private var failures: [String] = []
    private var passed = 0

    mutating func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("All architecture tests passed (\(passed) cases)")
            exit(0)
        }

        print("\nArchitecture test failures:")
        failures.forEach { print("- \($0)") }
        exit(1)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    let message: String

    var description: String {
        "\(file):\(line) \(message)"
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(file: file, line: line, message: message)
    }
}

private func approximatelyEqual<T: BinaryFloatingPoint>(
    _ lhs: T,
    _ rhs: T,
    tolerance: T = 0.000_001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func approximatelyEqual(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat = 0.000_001
) -> Bool {
    approximatelyEqual(lhs.origin.x, rhs.origin.x, tolerance: tolerance)
        && approximatelyEqual(lhs.origin.y, rhs.origin.y, tolerance: tolerance)
        && approximatelyEqual(lhs.size.width, rhs.size.width, tolerance: tolerance)
        && approximatelyEqual(lhs.size.height, rhs.size.height, tolerance: tolerance)
}

private func require<T>(
    _ value: T?,
    _ message: String = "required value was nil",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(file: file, line: line, message: message)
    }
    return value
}

private func waitForAsyncCallbacks() async throws {
    try await Task.sleep(nanoseconds: 80_000_000)
}

private func restoreDefaultsObject(_ object: Any?, forKey key: String) {
    if let object {
        UserDefaults.standard.set(object, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AtomVoiceArchitectureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeDummyFile(_ url: URL) throws {
    try Data([0x41]).write(to: url)
}

private func makePCMBuffer(
    sampleRate: Double,
    frameLength: AVAudioFrameCount,
    fillValue: Float? = nil,
    sine: (frequency: Double, amplitude: Float, phase: Double)? = nil
) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
    buffer.frameLength = frameLength
    if let channel = buffer.floatChannelData?[0] {
        if let sine {
            let twoPi = 2.0 * Double.pi
            for index in 0..<Int(frameLength) {
                let t = Double(index) / sampleRate
                channel[index] = sine.amplitude * Float(sin(twoPi * sine.frequency * t + sine.phase))
            }
        } else {
            for index in 0..<Int(frameLength) {
                channel[index] = fillValue ?? Float(index) / 100.0
            }
        }
    }
    return buffer
}

private func makeRecognitionSessionCallbacks(
    generationProvider: @escaping () -> Int = { 1 },
    isRecordingProvider: @escaping () -> Bool = { true },
    targetGeneration: Int = 1
) -> RecognitionSessionCallbacks {
    RecognitionSessionCallbacks(
        isCurrent: {
            generationProvider() == targetGeneration
        },
        isRecordingCurrent: {
            isRecordingProvider() && generationProvider() == targetGeneration
        },
        copyAudioBuffer: { buffer in buffer },
        onPartialResult: { _, _ in },
        onError: { _ in },
        onShowInitial: {},
        onShowRecording: {},
        onProgress: { _, _ in },
        onDisplayText: { _ in },
        onShimmerChanged: { _ in },
        onEffectiveEngineChanged: { _ in },
        onStartFailure: { _ in },
        onWaitingForFinalResultChanged: { _ in },
        onResetLiveInsertion: {}
    )
}

private final class FakePermissionAccess: PermissionAccessing {
    var statuses: [PermissionKind: PermissionStatus]
    var microphoneRequestResult = true
    var speechRecognitionRequestResult = true
    private(set) var requestedMicrophoneCount = 0
    private(set) var requestedSpeechRecognitionCount = 0
    private(set) var openedSettings: [PermissionKind] = []

    init(statuses: [PermissionKind: PermissionStatus]) {
        self.statuses = statuses
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .denied
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        requestedMicrophoneCount += 1
        completion(microphoneRequestResult)
    }

    func requestSpeechRecognition(completion: @escaping (Bool) -> Void) {
        requestedSpeechRecognitionCount += 1
        completion(speechRecognitionRequestResult)
    }

    func openSettings(for kind: PermissionKind) {
        openedSettings.append(kind)
    }
}

private final class FakeTextProcessor: TextPostProcessor {
    let id: String
    private let output: String?
    private(set) var callCount = 0
    private(set) var lastText: String?
    private(set) var lastContext: TextProcessingContext?

    init(id: String, output: String?) {
        self.id = id
        self.output = output
    }

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        callCount += 1
        lastText = text
        lastContext = context
        return output
    }
}

private final class RecognitionFinalizerHarness {
    let presenter = FakeRecognitionPresenter()
    let refiner = FakeRecognitionRefiner()
    let sink = FakeTextOutputSink()
    let settings: RecognitionFinalizerSettingsBox
    private(set) var clearedStreamCount = 0
    var generation = 0
    var isRefining = false
    private let finalizer: RecognitionResultFinalizer

    init(processors: [TextPostProcessor] = []) {
        let settings = RecognitionFinalizerSettingsBox()
        self.settings = settings
        let finalizer = RecognitionResultFinalizer(
            presenter: presenter,
            refiner: refiner,
            textPostProcessorRegistry: TextPostProcessorRegistry(processors: processors),
            outputSinkProvider: { [sink] in sink },
            settingsProvider: { settings.value }
        )
        self.finalizer = finalizer
        
        finalizer.onRefiningStateChanged = { [weak self] refining, _ in
            self?.isRefining = refining
        }
        finalizer.currentGenerationProvider = { [weak self] in
            self?.generation ?? 0
        }
    }

    func finish(
        _ text: String,
        mode: RecognitionFinalizationMode = .normal,
        errorMessage: String? = nil,
        liveInsertion: RecognitionLiveInsertionSnapshot = RecognitionLiveInsertionSnapshot(isActive: false, committedText: ""),
        streamSession: TextStreamSession? = nil
    ) {
        finalizer.finish(
            RecognitionResultFinalizer.Request(
                recognizedText: text,
                errorMessage: errorMessage,
                mode: mode,
                engineCode: ASREngineRegistry.appleCode,
                liveInsertion: liveInsertion,
                streamSession: streamSession,
                clearStreamSession: { [weak self] in self?.clearedStreamCount += 1 },
                generation: generation
            )
        )
    }

    func remainingText(_ text: String, committedText: String) -> String {
        finalizer.remainingTextAfterLiveInsertion(
            text,
            liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: committedText)
        )
    }
}

private final class RecognitionFinalizerSettingsBox {
    var value = RecognitionResultFinalizer.Settings(
        language: "en-US",
        llmEnabled: false,
        llmAPIKey: "",
        llmResultDelay: 0
    )

    var language: String {
        get { value.language }
        set { value.language = newValue }
    }

    var llmEnabled: Bool {
        get { value.llmEnabled }
        set { value.llmEnabled = newValue }
    }

    var llmAPIKey: String {
        get { value.llmAPIKey }
        set { value.llmAPIKey = newValue }
    }

    var llmResultDelay: Double {
        get { value.llmResultDelay }
        set { value.llmResultDelay = newValue }
    }
}

private final class FakeRecognitionPresenter: RecognitionResultPresenting {
    private(set) var events: [String] = []

    func updateRecognitionText(_ text: String) {
        events.append("update:\(text)")
    }

    func showRecognitionRefining() {
        events.append("refining")
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        events.append(String(format: "error:%@:%0.1f", message, dismissAfter))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        events.append("dismiss")
        completion?()
    }
}

private final class FakeRecognitionRefiner: RecognitionTextRefining {
    var nextProgress: String?
    var nextResult: String?
    var nextError: String?
    private(set) var requests: [String] = []
    var delayCompletion = false
    var pendingCompletion: ((String?, String?) -> Void)?
    var pendingOnProgress: ((String) -> Void)?

    func refine(
        text: String,
        onProgress: ((String) -> Void)?,
        completion: @escaping (String?, String?) -> Void
    ) {
        requests.append(text)
        if delayCompletion {
            pendingCompletion = completion
            pendingOnProgress = onProgress
        } else {
            if let nextProgress {
                onProgress?(nextProgress)
            }
            completion(nextResult, nextError)
        }
    }
}

private final class FakeTextOutputSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(
        code: "fake",
        displayNameKey: "fake",
        iconName: "fake",
        supportsStreaming: false
    )
    private(set) var deliveredTexts: [String] = []

    func deliver(text: String, completion: (() -> Void)?) {
        deliveredTexts.append(text)
        completion?()
    }
}

private final class FakeTextStreamSession: TextStreamSession {
    private(set) var updates: [String] = []
    private(set) var finalizedReplacements: [String?] = []
    private(set) var cancelCount = 0

    func update(currentText: String) {
        updates.append(currentText)
    }

    func finalize(replacingWith finalText: String?, completion: (() -> Void)?) {
        finalizedReplacements.append(finalText)
        completion?()
    }

    func cancel() {
        cancelCount += 1
    }
}
