import Foundation

enum RecordingCapsulePresentationRequest: Equatable {
    case none
    case initial
    case recording
    case progress(text: String, hidesWaveform: Bool)
    case progressKey(messageKey: String, hidesWaveform: Bool)
    case error(message: String, dismissAfter: TimeInterval)
    case errorKey(messageKey: String, dismissAfter: TimeInterval)
}

enum RecordingPhase: Equatable {
    case idle
    case starting
    case capturing
    case stopping
    case refining
    case cancelled
    case errored
}

enum RecordingEvent: Equatable {
    case triggerPressed(deferCapsulePresentation: Bool)
    case inputPreflightCompleted(request: Int, ready: Bool)
    case startPreflightFailed(message: String, ensurePanel: Bool)
    case externalModelDownloadRequired(redownload: Bool)
    case externalModelDownloadInProgress
    case recognitionCapabilitiesResolved(mutableCapsulePreview: Bool)
    case startValidated(
        engine: String,
        pendingDoubaoText: String?,
        pendingRefinementText: String?,
        lowerVolume: Bool
    )
    case sessionStartFailed(message: String, dismissAfter: TimeInterval, stopAudioEngine: Bool, recovery: RecordingRecovery?)
    case sessionStartCompleted(generation: Int)
    case triggerReleased
    case immediateStop(appending: String?)
    case cancelRequested
    case audioRouteRecoveryFailed
    case asrPartial(text: String, isFinal: Bool)
    case asrFinal(text: String, errorMessage: String?, appending: String?)
    case fallbackStarted(engine: String)
    case doubaoFinalWaitStarted
    case doubaoFinalWaitEnded
    case refiningStarted(text: String?)
    case refiningFinished
    case llmResult(text: String)
    case llmError(message: String)
    case timeout
    case textOutputActivated(liveInsertion: Bool)
    case deferredCapsuleReveal
    case capsulePresentationRequested(RecordingCapsulePresentationRequest)
    case capsuleTextUpdated(String)
    case capsuleBandsUpdated
    case shimmerChanged(Bool)
    case silenceMonitorGraceRequested(duration: TimeInterval)
    case liveInsertionProgressCleared
    case liveInsertionReset
    case liveInsertionDeferred(text: String, isFinal: Bool)
    case liveInsertionLatestObserved(text: String)
    case liveInsertionCommitted(segment: String, latestText: String)
    case liveInsertionCommitFinished
    case teardownCompleted
}

enum RecordingRecovery: Equatable {
    case requestSherpaModelDownload(redownload: Bool, delay: TimeInterval)
}

enum RecordingSideEffect: Equatable {
    case waitForInputReady(request: Int)
    case validateStart(request: Int)
    case startSession(generation: Int)
    case stopSession(generation: Int, immediate: Bool, appending: String?)
    case cancelSession(stopAudioEngine: Bool)
    case showCapsule(RecordingCapsulePresentationRequest, ensurePanel: Bool)
    case updateCapsuleText(String)
    case updateCapsuleBands
    case startShimmer
    case stopShimmer
    case dismissCapsule
    case deliverText(String)
    case startLLM(String)
    case cancelLLM
    case lowerVolume
    case restoreVolume
    case startSilenceMonitor
    case stopSilenceMonitor
    case extendSilenceMonitor(by: TimeInterval)
    case notifyRecording(Bool)
    case notifyRefining(Bool)
    case noteASRText(String)
    case activateTextOutput
    case resetStreamSession
    case clearSwitchedAudioRequest
    case resetAudioAnalyzer
    case abandonAudioRouteRecovery
    case notifySessionDidEnd
    case requestSherpaModelDownload(redownload: Bool, delay: TimeInterval)
}

struct RecordingLiveInsertionState: Equatable {
    var isActive = false
    var committedText = ""
    var latestText = ""
    var pasteInFlight = false

    mutating func clearProgress() {
        committedText = ""
        latestText = ""
        pasteInFlight = false
    }

    mutating func reset() {
        isActive = false
        clearProgress()
    }
}

struct RecordingDeferredCapsuleState: Equatable {
    var isDeferred = false
    var pendingPresentation: RecordingCapsulePresentationRequest = .none
    var pendingShimmer = false
    var recognizedText: String?
    var liveInsertionText: String?
    var liveInsertionIsFinal = false

    mutating func begin(deferred: Bool) {
        isDeferred = deferred
        pendingPresentation = .none
        pendingShimmer = false
        recognizedText = nil
        liveInsertionText = nil
        liveInsertionIsFinal = false
    }

    mutating func reset() {
        begin(deferred: false)
    }
}

struct RecordingSessionState: Equatable {
    fileprivate(set) var phase: RecordingPhase = .idle
    var currentRecordingEngine = ASREngineRegistry.appleCode
    fileprivate(set) var recordingGeneration = 0
    fileprivate(set) var startRequestGeneration = 0
    fileprivate(set) var isRefining = false
    fileprivate(set) var isWaitingForDoubaoFinalResult = false
    var pendingRefinementText: String?
    var mutableCapsulePreviewEnabled = true
    var textOutputActivated = false
    var liveInsertion = RecordingLiveInsertionState()
    var deferredCapsule = RecordingDeferredCapsuleState()

    var isRecording: Bool { phase == .capturing }
    var isStarting: Bool { phase == .starting }
    var isRecordingOrStarting: Bool { isRecording || isStarting }

    func acceptsStartRequest(_ request: Int) -> Bool {
        phase == .starting && startRequestGeneration == request
    }
}

struct RecordingStateMachine {
    static func reduce(
        _ state: RecordingSessionState,
        _ event: RecordingEvent
    ) -> (state: RecordingSessionState, sideEffects: [RecordingSideEffect]) {
        var next = state
        var effects: [RecordingSideEffect] = []

        switch event {
        case .triggerPressed(let deferCapsulePresentation):
            guard next.phase == .idle || next.phase == .refining || next.phase == .cancelled || next.phase == .errored else {
                return (next, effects)
            }
            next.deferredCapsule.begin(deferred: deferCapsulePresentation)
            next.mutableCapsulePreviewEnabled = true
            next.phase = .starting
            next.startRequestGeneration += 1
            effects.append(.waitForInputReady(request: next.startRequestGeneration))

        case .inputPreflightCompleted(let request, let ready):
            guard next.phase == .starting, next.startRequestGeneration == request else { break }
            if ready {
                effects.append(.validateStart(request: request))
            } else {
                next.phase = .errored
                effects.append(.showCapsule(.initial, ensurePanel: true))
                effects.append(.showCapsule(.errorKey(messageKey: "error.noInputDevice", dismissAfter: 5), ensurePanel: true))
            }

        case .startPreflightFailed(let message, let ensurePanel):
            guard next.phase == .starting else { break }
            next.phase = .errored
            if !message.isEmpty {
                effects.append(.showCapsule(.initial, ensurePanel: ensurePanel))
                effects.append(.showCapsule(.error(message: message, dismissAfter: 5), ensurePanel: ensurePanel))
            }

        case .externalModelDownloadRequired(let redownload):
            guard next.phase == .starting else { break }
            next.phase = .idle
            effects.append(.requestSherpaModelDownload(redownload: redownload, delay: 0))

        case .externalModelDownloadInProgress:
            guard next.phase == .starting else { break }
            next.phase = .idle

        case .recognitionCapabilitiesResolved(let mutableCapsulePreview):
            guard next.phase == .starting || next.phase == .capturing else { break }
            next.mutableCapsulePreviewEnabled = mutableCapsulePreview

        case .startValidated(let engine, let pendingDoubaoText, let pendingRefinementText, let lowerVolume):
            guard next.phase == .starting else { break }
            if next.isWaitingForDoubaoFinalResult {
                next.isWaitingForDoubaoFinalResult = false
                if let pendingDoubaoText, !pendingDoubaoText.isEmpty {
                    effects.append(.deliverText(pendingDoubaoText))
                }
            }
            if next.isRefining {
                next.isRefining = false
                next.pendingRefinementText = nil
                effects.append(.notifyRefining(false))
                if let pendingRefinementText, !pendingRefinementText.isEmpty {
                    effects.append(.deliverText(pendingRefinementText))
                }
            }
            next.phase = .capturing
            next.currentRecordingEngine = engine
            next.recordingGeneration += 1
            next.textOutputActivated = false
            next.liveInsertion.reset()
            effects.append(contentsOf: [
                .cancelLLM,
                .cancelSession(stopAudioEngine: false),
                .notifyRecording(true),
                .resetStreamSession,
                .activateTextOutput,
            ])
            if lowerVolume { effects.append(.lowerVolume) }
            effects.append(.startSession(generation: next.recordingGeneration))

        case .sessionStartCompleted(let generation):
            guard next.phase == .capturing, next.recordingGeneration == generation else { break }
            effects.append(.startSilenceMonitor)

        case .sessionStartFailed(let message, let dismissAfter, let stopAudioEngine, let recovery):
            next.phase = .errored
            next.textOutputActivated = false
            next.deferredCapsule.reset()
            next.liveInsertion.reset()
            effects.append(contentsOf: [
                .stopSilenceMonitor,
                .notifyRecording(false),
                .restoreVolume,
                .cancelSession(stopAudioEngine: stopAudioEngine),
                .showCapsule(.error(message: message, dismissAfter: dismissAfter), ensurePanel: false),
            ])
            if case .requestSherpaModelDownload(let redownload, let delay) = recovery {
                effects.append(.requestSherpaModelDownload(redownload: redownload, delay: delay))
            }

        case .triggerReleased:
            guard next.phase == .capturing else { break }
            next.phase = .stopping
            next.textOutputActivated = false
            next.deferredCapsule.reset()
            effects.append(contentsOf: commonStopEffects())
            effects.append(.stopSession(generation: next.recordingGeneration, immediate: false, appending: nil))

        case .immediateStop(let punctuation):
            guard next.phase == .capturing else { break }
            next.phase = .stopping
            next.textOutputActivated = false
            next.deferredCapsule.reset()
            effects.append(contentsOf: commonStopEffects())
            effects.append(.stopSession(generation: next.recordingGeneration, immediate: true, appending: punctuation))

        case .cancelRequested:
            guard next.phase == .capturing || next.isRefining else {
                if next.phase == .starting {
                    next.phase = .cancelled
                    next.startRequestGeneration += 1
                    next.deferredCapsule.reset()
                }
                break
            }
            next.phase = .cancelled
            next.recordingGeneration += 1
            next.startRequestGeneration += 1
            next.clearVolatileState()
            effects.append(contentsOf: commonStopEffects())
            effects.append(contentsOf: [
                .notifyRefining(false),
                .cancelLLM,
                .cancelSession(stopAudioEngine: true),
                .dismissCapsule,
                .notifySessionDidEnd,
            ])

        case .audioRouteRecoveryFailed:
            guard next.phase == .capturing else { break }
            next.phase = .errored
            next.clearVolatileState()
            effects.append(contentsOf: commonStopEffects())
            effects.append(contentsOf: [
                .abandonAudioRouteRecovery,
                .cancelLLM,
                .cancelSession(stopAudioEngine: false),
                .showCapsule(.errorKey(messageKey: "error.audioTapFailed", dismissAfter: 5), ensurePanel: false),
                .notifySessionDidEnd,
            ])

        case .asrPartial:
            if next.mutableCapsulePreviewEnabled, next.deferredCapsule.isDeferred {
                if case .asrPartial(let text, _) = event {
                    next.deferredCapsule.recognizedText = text
                }
            } else if next.mutableCapsulePreviewEnabled, case .asrPartial(let text, _) = event {
                effects.append(.updateCapsuleText(text))
            }
            if case .asrPartial(let text, _) = event {
                effects.append(.noteASRText(text))
            }

        case .asrFinal:
            next.phase = .idle

        case .fallbackStarted(let engine):
            next.currentRecordingEngine = engine
            effects.append(.showCapsule(.progressKey(messageKey: "menu.recognitionEngine.apple", hidesWaveform: false), ensurePanel: false))
            if next.phase == .capturing {
                // 豆包弱网回退后，Apple Speech 需要额外时间产出首个 partial，避免 ASR 静音监控立刻停录。
                effects.append(.extendSilenceMonitor(by: 3))
            }

        case .teardownCompleted:
            next.phase = .idle

        case .doubaoFinalWaitStarted:
            next.isWaitingForDoubaoFinalResult = true

        case .doubaoFinalWaitEnded:
            next.isWaitingForDoubaoFinalResult = false

        case .refiningStarted(let text):
            next.phase = .refining
            next.isRefining = true
            next.pendingRefinementText = text
            effects.append(.notifyRefining(true))

        case .refiningFinished:
            next.phase = .idle
            next.isRefining = false
            next.pendingRefinementText = nil
            effects.append(.notifyRefining(false))

        case .llmResult(let text):
            next.phase = .idle
            next.isRefining = false
            next.pendingRefinementText = nil
            effects.append(contentsOf: [.notifyRefining(false), .deliverText(text)])

        case .llmError(let message):
            next.phase = .errored
            next.isRefining = false
            next.pendingRefinementText = nil
            effects.append(contentsOf: [
                .notifyRefining(false),
                .showCapsule(.error(message: message, dismissAfter: 3), ensurePanel: false),
            ])

        case .timeout:
            guard next.phase == .capturing else { break }
            effects.append(.stopSession(generation: next.recordingGeneration, immediate: false, appending: nil))

        case .textOutputActivated(let liveInsertion):
            guard next.phase == .capturing, !next.textOutputActivated else { break }
            next.textOutputActivated = true
            next.liveInsertion.isActive = liveInsertion
            next.liveInsertion.clearProgress()

        case .deferredCapsuleReveal:
            next.deferredCapsule.reset()
            effects.append(.activateTextOutput)

        case .capsulePresentationRequested(let presentation):
            if next.deferredCapsule.isDeferred {
                next.deferredCapsule.pendingPresentation = presentation
            } else {
                effects.append(.showCapsule(presentation, ensurePanel: false))
            }

        case .capsuleTextUpdated(let text):
            if next.deferredCapsule.isDeferred {
                next.deferredCapsule.recognizedText = text
            } else {
                effects.append(.updateCapsuleText(text))
            }

        case .capsuleBandsUpdated:
            if !next.deferredCapsule.isDeferred {
                effects.append(.updateCapsuleBands)
            }

        case .shimmerChanged(let active):
            if next.deferredCapsule.isDeferred {
                next.deferredCapsule.pendingShimmer = active
            } else {
                effects.append(active ? .startShimmer : .stopShimmer)
            }

        case .silenceMonitorGraceRequested(let duration):
            if next.phase == .capturing {
                effects.append(.extendSilenceMonitor(by: duration))
            }

        case .liveInsertionProgressCleared:
            next.liveInsertion.clearProgress()

        case .liveInsertionReset:
            next.liveInsertion.reset()

        case .liveInsertionDeferred(let text, let isFinal):
            next.deferredCapsule.liveInsertionText = text
            next.deferredCapsule.liveInsertionIsFinal = next.deferredCapsule.liveInsertionIsFinal || isFinal

        case .liveInsertionLatestObserved(let text):
            guard next.liveInsertion.isActive else { break }
            next.liveInsertion.latestText = text

        case .liveInsertionCommitted(let segment, let latestText):
            next.liveInsertion.latestText = latestText
            next.liveInsertion.committedText += segment
            next.liveInsertion.pasteInFlight = true
            effects.append(.deliverText(segment))

        case .liveInsertionCommitFinished:
            next.liveInsertion.pasteInFlight = false

        }

        return (next, effects)
    }

    private static func commonStopEffects() -> [RecordingSideEffect] {
        [
            .stopSilenceMonitor,
            .notifyRecording(false),
            .restoreVolume,
            .clearSwitchedAudioRequest,
            .resetAudioAnalyzer,
        ]
    }
}

private extension RecordingSessionState {
    mutating func clearVolatileState() {
        isRefining = false
        isWaitingForDoubaoFinalResult = false
        pendingRefinementText = nil
        mutableCapsulePreviewEnabled = true
        textOutputActivated = false
        liveInsertion.reset()
        deferredCapsule.reset()
    }
}
