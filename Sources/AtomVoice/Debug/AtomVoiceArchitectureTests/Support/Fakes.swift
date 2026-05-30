import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

final class FakePermissionAccess: PermissionAccessing {
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

final class FakeTextProcessor: TextPostProcessor {
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

final class FakeRecognitionPresenter: RecognitionResultPresenting {
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

final class FakeRecordingSessionPresenter: RecordingSessionPresenting {
    private(set) var events: [RecordingSessionPresentationEvent] = []
    private(set) var dismissCount = 0
    var isShowingError = false

    func present(_ event: RecordingSessionPresentationEvent) {
        events.append(event)
        if case .showError = event {
            isShowingError = true
        }
    }

    func dismiss(completion: (() -> Void)?) {
        dismissCount += 1
        isShowingError = false
        completion?()
    }

    func updateRecognitionText(_ text: String) {
        present(.updateText(text))
    }

    func showRecognitionRefining() {
        present(.showRefining)
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        present(.showError(message: message, dismissAfter: dismissAfter, ensurePanel: false))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        dismiss(completion: completion)
    }
}

final class FakeRecognitionRefiner: RecognitionTextRefining {
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

final class FakeTextOutputSink: TextOutputSink {
    let descriptor: TextOutputSinkDescriptor
    var streamSession: TextStreamSession?
    var completesDeliveriesImmediately: Bool
    private(set) var deliveredTexts: [String] = []
    private(set) var beginStreamCount = 0
    private(set) var pendingDeliveryCompletions: [(() -> Void)?] = []

    init(
        code: String = "fake",
        displayNameKey: String = "fake",
        iconName: String = "fake",
        supportsStreaming: Bool = false,
        streamSession: TextStreamSession? = nil,
        completesDeliveriesImmediately: Bool = true
    ) {
        self.descriptor = TextOutputSinkDescriptor(
            code: code,
            displayNameKey: displayNameKey,
            iconName: iconName,
            supportsStreaming: supportsStreaming
        )
        self.streamSession = streamSession
        self.completesDeliveriesImmediately = completesDeliveriesImmediately
    }

    func deliver(text: String, completion: (() -> Void)?) {
        deliveredTexts.append(text)
        if completesDeliveriesImmediately {
            completion?()
        } else {
            pendingDeliveryCompletions.append(completion)
        }
    }

    func completeNextDelivery() {
        guard !pendingDeliveryCompletions.isEmpty else { return }
        let completion = pendingDeliveryCompletions.removeFirst()
        completion?()
    }

    func beginStream() -> TextStreamSession? {
        beginStreamCount += 1
        return streamSession
    }
}

final class FakeTextStreamSession: TextStreamSession {
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

final class FakeRecognitionSession: RecognitionSession {
    let code: String
    var currentText: String
    var supportsMutableCapsulePreview: Bool
    var supportsLiveInsertion: Bool
    var supportsServerFallback: Bool
    var supportsSilenceMonitoring: Bool
    var requiresModelReloadOnRouteChange: Bool
    var preferredAudioFormat: AudioRouter.ConsumerFormat?
    var preflightResult: RecognitionSessionPreflightResult = .ready
    var startResult: RecognitionSessionStartResult = .started
    var stopResult: RecognitionSessionStopResult?
    var completesStopImmediately = true

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCount = 0
    private(set) var startAudioFormats: [AudioRouter.ConsumerFormat?] = []
    private(set) var lastStartCallbacks: RecognitionSessionCallbacks?
    private(set) var lastStopCallbacks: RecognitionSessionCallbacks?
    private(set) var lastStopImmediate = false
    private(set) var lastStopPunctuation: String?
    private(set) var copiedAudioBuffers: [AVAudioPCMBuffer] = []
    private var pendingStopCompletion: ((RecognitionSessionStopResult) -> Void)?

    init(
        code: String = ASREngineRegistry.appleCode,
        currentText: String = "",
        supportsMutableCapsulePreview: Bool = true,
        supportsLiveInsertion: Bool = true,
        supportsServerFallback: Bool = false,
        supportsSilenceMonitoring: Bool = true,
        requiresModelReloadOnRouteChange: Bool = false,
        preferredAudioFormat: AudioRouter.ConsumerFormat? = nil
    ) {
        self.code = code
        self.currentText = currentText
        self.supportsMutableCapsulePreview = supportsMutableCapsulePreview
        self.supportsLiveInsertion = supportsLiveInsertion
        self.supportsServerFallback = supportsServerFallback
        self.supportsSilenceMonitoring = supportsSilenceMonitoring
        self.requiresModelReloadOnRouteChange = requiresModelReloadOnRouteChange
        self.preferredAudioFormat = preferredAudioFormat
    }

    func preflight() -> RecognitionSessionPreflightResult {
        preflightResult
    }

    func start(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        startCallCount += 1
        startAudioFormats.append(audioFormat)
        lastStartCallbacks = callbacks
        return startResult
    }

    func stop(
        immediate: Bool,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) {
        stopCallCount += 1
        lastStopImmediate = immediate
        lastStopPunctuation = punctuation
        lastStopCallbacks = callbacks
        let result = resolvedStopResult(immediate: immediate, punctuation: punctuation)
        if completesStopImmediately {
            completion(result)
        } else {
            pendingStopCompletion = completion
        }
    }

    func cancel() {
        cancelCount += 1
    }

    @discardableResult
    func acceptAudio(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = lastStartCallbacks?.copyAudioBuffer(buffer) else { return nil }
        copiedAudioBuffers.append(copy)
        return copy
    }

    func emitPartial(_ text: String, isFinal: Bool = false) {
        currentText = text
        lastStartCallbacks?.onPartialResult(text, isFinal)
    }

    func emitError(_ message: String) {
        lastStartCallbacks?.onError(message)
    }

    func completeStop(with result: RecognitionSessionStopResult? = nil) {
        guard let completion = pendingStopCompletion else { return }
        pendingStopCompletion = nil
        completion(result ?? resolvedStopResult(immediate: lastStopImmediate, punctuation: lastStopPunctuation))
    }

    private func resolvedStopResult(immediate: Bool, punctuation: String?) -> RecognitionSessionStopResult {
        stopResult ?? RecognitionSessionStopResult(
            text: currentText,
            errorMessage: nil,
            appendingImmediatePunctuation: immediate ? punctuation : nil
        )
    }
}

final class FakeASREngineProvider: ASREngineProviding {
    var hasSherpaEngineValue = false
    var isSherpaModelLoadedValue = false
    private(set) var releaseCount = 0
    private(set) var requestedRecognitionCodes: [String] = []
    private(set) var requestedAudioEngines: [AudioEngineController] = []
    private var sessionsByCode: [String: any RecognitionSession] = [:]

    init(sessions: [String: any RecognitionSession] = [:]) {
        self.sessionsByCode = sessions
    }

    var hasSherpaEngine: Bool { hasSherpaEngineValue }
    var isSherpaModelLoaded: Bool { isSherpaModelLoadedValue }

    func register(_ session: any RecognitionSession, for code: String? = nil) {
        sessionsByCode[code ?? session.code] = session
    }

    func recognitionSession(for code: String, audioEngine: AudioEngineController) -> any RecognitionSession {
        requestedRecognitionCodes.append(code)
        requestedAudioEngines.append(audioEngine)
        if let session = sessionsByCode[code] {
            return session
        }
        let session = FakeRecognitionSession(code: code)
        sessionsByCode[code] = session
        return session
    }

    func releaseSherpaEngine() {
        releaseCount += 1
        hasSherpaEngineValue = false
        isSherpaModelLoadedValue = false
        sessionsByCode[ASREngineRegistry.sherpaCode] = nil
    }

    func speechRecognizer() -> SpeechRecognizerController {
        fatalError("FakeASREngineProvider does not create real engines")
    }

    func appleEngine() -> AppleSpeechASREngine {
        fatalError("FakeASREngineProvider does not create real engines")
    }

    func sherpaEngine() -> SherpaOnnxASREngine {
        fatalError("FakeASREngineProvider does not create real engines")
    }

    func volcengineEngine() -> VolcengineASREngine {
        fatalError("FakeASREngineProvider does not create real engines")
    }
}

final class FakeRecordingSessionDelegate: RecordingSessionDelegate {
    private(set) var downloadRequests: [Bool] = []
    private(set) var sessionDidEndCount = 0

    func sessionRequiresSherpaModelDownload(redownload: Bool) {
        downloadRequests.append(redownload)
    }

    func sessionDidEnd() {
        sessionDidEndCount += 1
    }
}
