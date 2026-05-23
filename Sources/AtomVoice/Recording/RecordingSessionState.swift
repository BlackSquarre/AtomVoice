import Foundation

enum RecordingCapsulePresentationRequest: Equatable {
    case none
    case initial
    case recording
    case progress(text: String, hidesWaveform: Bool)
    case error(message: String, dismissAfter: TimeInterval)
}

enum RecordingSessionPhase: Equatable {
    case idle
    case starting
    case recording
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
    private(set) var phase: RecordingSessionPhase = .idle
    var currentRecordingEngine = ASREngineRegistry.appleCode
    private(set) var recordingGeneration = 0
    private(set) var startRequestGeneration = 0
    private(set) var isRefining = false
    private(set) var isWaitingForDoubaoFinalResult = false
    var pendingRefinementText: String?
    var textOutputActivated = false
    var liveInsertion = RecordingLiveInsertionState()
    var deferredCapsule = RecordingDeferredCapsuleState()

    var isRecording: Bool { phase == .recording }
    var isStarting: Bool { phase == .starting }
    var isRecordingOrStarting: Bool { isRecording || isStarting }

    mutating func beginStart(deferredCapsulePresentation: Bool) -> Int? {
        guard !isRecording, !isStarting else { return nil }
        deferredCapsule.begin(deferred: deferredCapsulePresentation)
        phase = .starting
        startRequestGeneration += 1
        return startRequestGeneration
    }

    func acceptsStartRequest(_ request: Int) -> Bool {
        isStarting && startRequestGeneration == request && !isRecording
    }

    mutating func failStart() {
        guard isStarting else { return }
        phase = .idle
    }

    mutating func cancelPendingStart() -> Bool {
        guard isStarting else { return false }
        phase = .idle
        startRequestGeneration += 1
        deferredCapsule.reset()
        return true
    }

    mutating func transitionToRecording(engine: String) -> Int {
        phase = .recording
        currentRecordingEngine = engine
        recordingGeneration += 1
        textOutputActivated = false
        liveInsertion.reset()
        return recordingGeneration
    }

    mutating func markRecordingStopped() {
        _ = cancelPendingStart()
        if isRecording {
            phase = .idle
        }
        textOutputActivated = false
        deferredCapsule.reset()
    }

    mutating func invalidateGenerationForCancel() {
        recordingGeneration += 1
    }

    mutating func beginRefining(text: String?) {
        isRefining = true
        pendingRefinementText = text
    }

    @discardableResult
    mutating func endRefining() -> String? {
        let pending = pendingRefinementText
        pendingRefinementText = nil
        isRefining = false
        return pending
    }

    mutating func beginDoubaoFinalWait() {
        isWaitingForDoubaoFinalResult = true
    }

    mutating func endDoubaoFinalWait() {
        isWaitingForDoubaoFinalResult = false
    }

    mutating func clearInterruptedState() {
        isRefining = false
        isWaitingForDoubaoFinalResult = false
        pendingRefinementText = nil
        textOutputActivated = false
        liveInsertion.reset()
    }

    mutating func resetDeferredCapsulePresentation() {
        deferredCapsule.reset()
    }

    mutating func beginTextOutputActivation() -> Bool {
        guard isRecording, !textOutputActivated else { return false }
        textOutputActivated = true
        return true
    }
}
