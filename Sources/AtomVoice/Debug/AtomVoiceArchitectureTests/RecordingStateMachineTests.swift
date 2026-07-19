import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum RecordingStateMachineTests {
    static func run(_ runner: inout TestRunner) async {
        func collectSnapshot(_ events: [RecordingEvent]) -> (state: RecordingSessionState, effects: [RecordingSideEffect]) {
            var state = RecordingSessionState()
            var effects: [RecordingSideEffect] = []
            for event in events {
                let result = RecordingStateMachine.reduce(state, event)
                state = result.state
                effects.append(contentsOf: result.sideEffects)
            }
            return (state, effects)
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
            try expect(!capturing.sideEffects.contains(.startSilenceMonitor))

            let started = RecordingStateMachine.reduce(
                capturing.state,
                .sessionStartCompleted(generation: 1)
            )
            try expect(started.sideEffects == [.startSilenceMonitor])
        }
        await runner.run("Recording state machine extends silence monitor during model loading grace") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(
                &state,
                .startValidated(
                    engine: ASREngineRegistry.sherpaCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                )
            )

            let result = RecordingStateMachine.reduce(state, .silenceMonitorGraceRequested(duration: 15))

            try expect(result.sideEffects == [.extendSilenceMonitor(by: 15)])
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
                .showCapsule(.progressKey(messageKey: "menu.recognitionEngine.apple", hidesWaveform: false), ensurePanel: false),
                .extendSilenceMonitor(by: 3)
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
        await runner.run("Recording state machine hides mutable partial text when model disables capsule preview") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(&state, .recognitionCapabilitiesResolved(mutableCapsulePreview: false))
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

            try expect(!partial.sideEffects.contains(.updateCapsuleText("hello")))
            try expect(partial.sideEffects.contains(.noteASRText("hello")))
        }
        await runner.run("Recording state machine updates final partial while stopping") {
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
            step(&state, .triggerReleased)

            let finalPartial = RecordingStateMachine.reduce(state, .asrPartial(text: "hello final", isFinal: true))

            try expect(finalPartial.state.phase == .stopping)
            try expect(finalPartial.sideEffects.contains(.updateCapsuleText("hello final")))
            try expect(finalPartial.sideEffects.contains(.noteASRText("hello final")))
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
        await runner.run("Reducer normal recording flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "hel", isFinal: false),
                .asrPartial(text: "hello", isFinal: false),
                .triggerReleased,
                .asrFinal(text: "hello.", errorMessage: nil, appending: nil),
            ])

            try expect(snapshot.effects.count == 19)
            try expect(snapshot.effects[0] == .waitForInputReady(request: 1))
            try expect(snapshot.effects[1] == .validateStart(request: 1))
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .updateCapsuleText("hel"))
            try expect(snapshot.effects[18] == .stopSession(generation: 1, immediate: false, appending: nil))
            try expect(snapshot.state.phase == .idle)
        }
        await runner.run("Reducer cancel recording flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "cancel me", isFinal: false),
                .cancelRequested,
            ])

            try expect(snapshot.effects.count == 21)
            try expect(snapshot.effects[0] == .waitForInputReady(request: 1))
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .updateCapsuleText("cancel me"))
            try expect(snapshot.effects[16] == .notifyRefining(false))
            try expect(snapshot.effects[18] == .cancelSession(stopAudioEngine: true))
            try expect(snapshot.effects[20] == .notifySessionDidEnd)
            try expect(snapshot.state.phase == .cancelled)
        }
        await runner.run("Reducer Doubao fallback flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: VolcengineASRSettings.engineCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "cloud draft", isFinal: false),
                .fallbackStarted(engine: ASREngineRegistry.appleCode),
                .triggerReleased,
                .asrFinal(text: "cloud final", errorMessage: nil, appending: nil),
            ])

            try expect(snapshot.effects.count == 19)
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .updateCapsuleText("cloud draft"))
            try expect(snapshot.effects[11] == .showCapsule(.progressKey(messageKey: "menu.recognitionEngine.apple", hidesWaveform: false), ensurePanel: false))
            try expect(snapshot.effects[12] == .extendSilenceMonitor(by: 3))
            try expect(snapshot.effects[18] == .stopSession(generation: 1, immediate: false, appending: nil))
            try expect(snapshot.state.currentRecordingEngine == ASREngineRegistry.appleCode)
            try expect(snapshot.state.phase == .idle)
        }
        await runner.run("Reducer immediate stop punctuation flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "question", isFinal: false),
                .immediateStop(appending: "?"),
                .asrFinal(text: "question?", errorMessage: nil, appending: "?"),
            ])

            try expect(snapshot.effects.count == 17)
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .updateCapsuleText("question"))
            try expect(snapshot.effects[16] == .stopSession(generation: 1, immediate: true, appending: "?"))
            try expect(snapshot.state.phase == .idle)
        }
        await runner.run("Reducer audio route recovery failure flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "route text", isFinal: false),
                .audioRouteRecoveryFailed,
            ])

            try expect(snapshot.effects.count == 21)
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[11] == .stopSilenceMonitor)
            try expect(snapshot.effects[16] == .abandonAudioRouteRecovery)
            try expect(snapshot.effects[18] == .cancelSession(stopAudioEngine: false))
            try expect(snapshot.effects[19] == .showCapsule(.errorKey(messageKey: "error.audioTapFailed", dismissAfter: 5), ensurePanel: false))
            try expect(snapshot.effects[20] == .notifySessionDidEnd)
            try expect(snapshot.state.phase == .errored)
        }
        await runner.run("Reducer refining interruption flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .triggerReleased,
                .asrFinal(text: "draft", errorMessage: nil, appending: nil),
                .refiningStarted(text: "draft"),
                .triggerPressed(deferCapsulePresentation: false),
            ])

            try expect(snapshot.effects.count == 17)
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[14] == .stopSession(generation: 1, immediate: false, appending: nil))
            try expect(snapshot.effects[15] == .notifyRefining(true))
            try expect(snapshot.effects[16] == .waitForInputReady(request: 2))
            try expect(snapshot.state.phase == .starting)
            try expect(snapshot.state.isRefining)
        }
        await runner.run("Reducer deferred capsule reveal flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: true),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .asrPartial(text: "buffered", isFinal: false),
                .deferredCapsuleReveal,
            ])

            try expect(snapshot.effects.count == 11)
            try expect(snapshot.effects[0] == .waitForInputReady(request: 1))
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .noteASRText("buffered"))
            try expect(snapshot.effects[10] == .activateTextOutput)
            try expect(!snapshot.effects.contains(.updateCapsuleText("buffered")))
            try expect(!snapshot.state.deferredCapsule.isDeferred)
            try expect(snapshot.state.phase == .capturing)
        }
        await runner.run("Reducer live insertion commit flow snapshot") {
            let snapshot = collectSnapshot([
                .triggerPressed(deferCapsulePresentation: false),
                .inputPreflightCompleted(request: 1, ready: true),
                .startValidated(
                    engine: ASREngineRegistry.appleCode,
                    pendingDoubaoText: nil,
                    pendingRefinementText: nil,
                    lowerVolume: false
                ),
                .sessionStartCompleted(generation: 1),
                .textOutputActivated(liveInsertion: true),
                .liveInsertionCommitted(segment: "hello", latestText: "hello"),
                .liveInsertionCommitFinished,
            ])

            try expect(snapshot.effects.count == 10)
            try expect(snapshot.effects[0] == .waitForInputReady(request: 1))
            try expect(snapshot.effects[7] == .startSession(generation: 1))
            try expect(snapshot.effects[9] == .deliverText("hello"))
            try expect(snapshot.state.phase == .capturing)
            try expect(snapshot.state.liveInsertion.isActive)
            try expect(snapshot.state.liveInsertion.committedText == "hello")
            try expect(!snapshot.state.liveInsertion.pasteInFlight)
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
    }
}
