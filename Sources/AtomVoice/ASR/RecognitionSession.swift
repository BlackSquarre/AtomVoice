import AVFoundation
import Foundation

enum RecognitionSessionPreflightResult: Equatable {
    case ready
    case requestExternalDownload(redownload: Bool)
    case waitForExternalDownload
    case failure(String)
}

enum RecognitionSessionRecovery: Equatable {
    case requestSherpaModelDownload(redownload: Bool, delay: TimeInterval)
}

struct RecognitionSessionFailure {
    let message: String
    let dismissAfter: TimeInterval
    let stopAudioEngine: Bool
    let recovery: RecognitionSessionRecovery?

    static func audioStartFailure() -> RecognitionSessionFailure {
        RecognitionSessionFailure(
            message: loc("error.audioTapFailed"),
            dismissAfter: 5,
            stopAudioEngine: false,
            recovery: nil
        )
    }
}

enum RecognitionSessionStartResult {
    case started
    case failed(RecognitionSessionFailure)
}

struct RecognitionSessionStopResult {
    let text: String
    let errorMessage: String?
    let appendingImmediatePunctuation: String?
}

struct RecognitionSessionCallbacks {
    let isCurrent: () -> Bool
    let isRecordingCurrent: () -> Bool
    let copyAudioBuffer: (AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    let onPartialResult: (_ text: String, _ isFinal: Bool) -> Void
    let onError: (_ message: String) -> Void
    let onShowInitial: () -> Void
    let onShowRecording: () -> Void
    let onProgress: (_ text: String, _ hidesWaveform: Bool) -> Void
    let onDisplayText: (_ text: String) -> Void
    let onShimmerChanged: (_ active: Bool) -> Void
    let onEffectiveEngineChanged: (_ code: String) -> Void
    let onStartFailure: (_ failure: RecognitionSessionFailure) -> Void
    let onWaitingForFinalResultChanged: (_ waiting: Bool) -> Void
    let onResetLiveInsertion: () -> Void
}

protocol RecognitionSession: AnyObject {
    var code: String { get }
    var currentText: String { get }
    var supportsLiveInsertion: Bool { get }
    var supportsServerFallback: Bool { get }
    var supportsSilenceMonitoring: Bool { get }
    var requiresModelReloadOnRouteChange: Bool { get }
    var preferredAudioFormat: AudioRouter.ConsumerFormat? { get }

    func preflight() -> RecognitionSessionPreflightResult
    func start(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult
    func stop(
        immediate: Bool,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    )
    func cancel()
}

extension RecognitionSession {
    var supportsSilenceMonitoring: Bool { true }
    var requiresModelReloadOnRouteChange: Bool { false }
    func preflight() -> RecognitionSessionPreflightResult { .ready }
}

final class AppleRecognitionSession: RecognitionSession {
    let code = ASREngineRegistry.appleCode
    let supportsLiveInsertion = true
    let supportsServerFallback = false
    let preferredAudioFormat: AudioRouter.ConsumerFormat? = nil

    private let engine: AppleSpeechASREngine
    private let audioEngine: AudioEngineController
    private var activeRouterConsumerID: UUID?

    init(engine: AppleSpeechASREngine, audioEngine: AudioEngineController) {
        self.engine = engine
        self.audioEngine = audioEngine
    }

    var currentText: String { engine.currentText }

    func start(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        callbacks.onShowInitial()
        if let error = engine.start(
            onResult: { text, isFinal in
                DispatchQueue.main.async {
                    guard callbacks.isRecordingCurrent() else { return }
                    callbacks.onPartialResult(text, isFinal)
                }
            },
            onError: { error in
                DispatchQueue.main.async {
                    guard callbacks.isRecordingCurrent() else { return }
                    callbacks.onError(error)
                }
            }
        ) {
            return .failed(
                RecognitionSessionFailure(
                    message: error,
                    dismissAfter: 5,
                    stopAudioEngine: false,
                    recovery: nil
                )
            )
        }

        guard audioEngine.start() else {
            engine.cancel()
            return .failed(.audioStartFailure())
        }

        activeRouterConsumerID = audioEngine.router.register(format: audioFormat) { [weak self] buffer in
            guard callbacks.isRecordingCurrent() else { return }
            self?.engine.accept(buffer: buffer)
        }
        return .started
    }

    func stop(
        immediate: Bool,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) {
        let text = engine.stopSynchronously()
        audioEngine.stop()
        unregisterConsumer()
        audioEngine.releaseHardwareAfterIdle()
        completion(
            RecognitionSessionStopResult(
                text: text,
                errorMessage: nil,
                appendingImmediatePunctuation: immediate ? punctuation : nil
            )
        )
    }

    func cancel() {
        engine.cancel()
        unregisterConsumer()
    }

    private func unregisterConsumer() {
        if let id = activeRouterConsumerID {
            audioEngine.router.unregister(id)
            activeRouterConsumerID = nil
        }
    }
}

final class SherpaRecognitionSession: RecognitionSession {
    let code = ASREngineRegistry.sherpaCode
    let supportsLiveInsertion = false
    let supportsServerFallback = false
    let requiresModelReloadOnRouteChange = true
    let preferredAudioFormat: AudioRouter.ConsumerFormat? = .voice16k

    private let engine: SherpaOnnxASREngine
    private let audioEngine: AudioEngineController
    private let preload = SherpaPreloadCoordinator()
    private var activeRouterConsumerID: UUID?

    init(engine: SherpaOnnxASREngine, audioEngine: AudioEngineController) {
        self.engine = engine
        self.audioEngine = audioEngine
    }

    var currentText: String { engine.currentText }

    func preflight() -> RecognitionSessionPreflightResult {
        guard SherpaModelDownloader.isReady() else {
            return SherpaModelDownloader.shared.isDownloading
                ? .waitForExternalDownload
                : .requestExternalDownload(redownload: false)
        }
        return .ready
    }

    func start(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        if engine.isModelLoaded {
            callbacks.onShowInitial()
            return startAfterModelLoad(audioFormat: audioFormat, callbacks: callbacks)
        }
        return startWithDeferredModel(audioFormat: audioFormat, callbacks: callbacks)
    }

    func stop(
        immediate: Bool,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) {
        let text = engine.stopSynchronously()
        audioEngine.stop()
        preload.cancel()
        unregisterConsumer()
        audioEngine.releaseHardwareAfterIdle()
        completion(
            RecognitionSessionStopResult(
                text: text,
                errorMessage: nil,
                appendingImmediatePunctuation: immediate ? punctuation : nil
            )
        )
    }

    func cancel() {
        preload.cancel()
        engine.cancel()
        unregisterConsumer()
    }

    private func startAfterModelLoad(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        if let error = engine.start(
            onResult: { text, _ in
                DispatchQueue.main.async {
                    guard callbacks.isRecordingCurrent() else { return }
                    callbacks.onPartialResult(text, false)
                }
            },
            onError: { _ in }
        ) {
            return .failed(startFailure(for: error, stopAudioEngine: false))
        }

        callbacks.onShowRecording()
        guard audioEngine.start() else {
            engine.cancel()
            return .failed(.audioStartFailure())
        }
        registerLiveConsumer(audioFormat: audioFormat, callbacks: callbacks)
        return .started
    }

    private func startWithDeferredModel(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        preload.begin()
        callbacks.onProgress(loc("sherpa.loadingModel"), true)

        guard audioEngine.start() else {
            preload.cancel()
            return .failed(.audioStartFailure())
        }

        activeRouterConsumerID = audioEngine.router.register(format: audioFormat) { [weak self] buffer in
            guard let self, callbacks.isRecordingCurrent() else { return }
            let buffered = self.preload.appendIfActive(buffer, copyBuffer: callbacks.copyAudioBuffer)
            if !buffered {
                self.engine.accept(buffer: buffer)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.engine.start(
                onResult: { text, _ in
                    DispatchQueue.main.async {
                        guard callbacks.isRecordingCurrent() else { return }
                        callbacks.onPartialResult(text, false)
                    }
                },
                onError: { _ in }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard callbacks.isRecordingCurrent() else {
                    self.preload.cancel()
                    return
                }

                if let error {
                    self.preload.cancel()
                    callbacks.onStartFailure(self.startFailure(for: error, stopAudioEngine: true))
                    return
                }

                self.preload.drain(
                    accept: { [weak self] buffer in
                        self?.engine.accept(buffer: buffer)
                    },
                    onComplete: {
                        DispatchQueue.main.async {
                            guard callbacks.isRecordingCurrent() else { return }
                            callbacks.onShimmerChanged(false)
                            callbacks.onShowRecording()
                        }
                    }
                )
            }
        }

        return .started
    }

    private func registerLiveConsumer(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) {
        activeRouterConsumerID = audioEngine.router.register(format: audioFormat) { [weak self] buffer in
            guard callbacks.isRecordingCurrent() else { return }
            self?.engine.accept(buffer: buffer)
        }
    }

    private func startFailure(for error: String, stopAudioEngine: Bool) -> RecognitionSessionFailure {
        let failureKind = engine.lastStartFailureKind
        let needsRedownload =
            failureKind == .missingRuntime ||
            failureKind == .missingModel ||
            failureKind == .invalidModel

        return RecognitionSessionFailure(
            message: error,
            dismissAfter: needsRedownload ? 3 : 6,
            stopAudioEngine: stopAudioEngine,
            recovery: needsRedownload ? .requestSherpaModelDownload(redownload: true, delay: 3.5) : nil
        )
    }

    private func unregisterConsumer() {
        if let id = activeRouterConsumerID {
            audioEngine.router.unregister(id)
            activeRouterConsumerID = nil
        }
    }
}

final class DoubaoRecognitionSession: RecognitionSession {
    let code = VolcengineASRSettings.engineCode
    let supportsLiveInsertion = false
    let supportsServerFallback = true
    let preferredAudioFormat: AudioRouter.ConsumerFormat? = .voice16k

    private let cloudEngine: VolcengineASREngine
    private let appleSession: AppleRecognitionSession
    private let speechRecognizerProvider: () -> SpeechRecognizerController
    private let audioEngine: AudioEngineController
    private let fallback = DoubaoFallbackCoordinator()
    private lazy var appleLiveFallback = AppleLiveFallbackStrategy(
        audioEngine: audioEngine,
        fallback: fallback,
        speechRecognizerProvider: speechRecognizerProvider
    )
    private var activeRouterConsumerID: UUID?
    private var usingAppleStartFallback = false

    #if DEBUG
    var debugIsUsingAppleStartFallback: Bool { usingAppleStartFallback }
    #endif

    init(
        cloudEngine: VolcengineASREngine,
        appleEngine: AppleSpeechASREngine,
        speechRecognizerProvider: @escaping () -> SpeechRecognizerController,
        audioEngine: AudioEngineController
    ) {
        self.cloudEngine = cloudEngine
        self.appleSession = AppleRecognitionSession(engine: appleEngine, audioEngine: audioEngine)
        self.speechRecognizerProvider = speechRecognizerProvider
        self.audioEngine = audioEngine
    }

    var currentText: String {
        usingAppleStartFallback ? appleSession.currentText : cloudEngine.currentText
    }

    func preflight() -> RecognitionSessionPreflightResult {
        guard AppSettings.doubaoASRPrivacyAccepted else {
            return .failure(loc("doubao.error.privacyNotAccepted"))
        }
        if let error = cloudEngine.validate() {
            return .failure(error)
        }
        return .ready
    }

    func start(
        audioFormat: AudioRouter.ConsumerFormat?,
        callbacks: RecognitionSessionCallbacks
    ) -> RecognitionSessionStartResult {
        DebugLog.info("[Session] 启动豆包录音")
        fallback.beginWaitingForFirstResult()
        callbacks.onShowInitial()
        callbacks.onShowRecording()
        DispatchQueue.main.async {
            guard callbacks.isRecordingCurrent() else { return }
            callbacks.onShimmerChanged(true)
        }

        if let error = cloudEngine.start(
            onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    guard let self, callbacks.isRecordingCurrent() else { return }
                    if self.fallback.acceptCloudText(text) {
                        callbacks.onShimmerChanged(false)
                    }
                    callbacks.onPartialResult(text, false)
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, callbacks.isRecordingCurrent() else { return }
                    self.handleRecognitionError(message, callbacks: callbacks)
                }
            }
        ) {
            fallback.reset()
            usingAppleStartFallback = true
            callbacks.onEffectiveEngineChanged(ASREngineRegistry.appleCode)
            DebugLog.error("[Doubao] 启动失败，回退到 Apple Speech: \(error)")
            let result = appleSession.start(audioFormat: nil, callbacks: callbacks)
            callbacks.onProgress(loc("menu.recognitionEngine.apple"), false)
            return result
        }

        guard audioEngine.start() else {
            cloudEngine.cancel()
            return .failed(.audioStartFailure())
        }

        activeRouterConsumerID = audioEngine.router.register(format: audioFormat) { [weak self] buffer in
            guard let self, callbacks.isRecordingCurrent() else { return }
            self.fallback.appendAudioBufferIfWaiting(buffer, copyBuffer: callbacks.copyAudioBuffer)
            self.cloudEngine.accept(buffer: buffer)
        }
        return .started
    }

    func stop(
        immediate: Bool,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) {
        if usingAppleStartFallback {
            usingAppleStartFallback = false
            appleSession.stop(
                immediate: immediate,
                appending: punctuation,
                callbacks: callbacks,
                completion: completion
            )
            return
        }

        audioEngine.stop()
        unregisterConsumer()

        if consumeFallbackIfNeeded(appending: immediate ? punctuation : nil, callbacks: callbacks, completion: completion) {
            return
        }

        if immediate {
            let text = cloudEngine.currentText
            cloudEngine.cancel()
            fallback.reset()
            audioEngine.releaseHardwareAfterIdle()
            completion(
                RecognitionSessionStopResult(
                    text: text,
                    errorMessage: nil,
                    appendingImmediatePunctuation: punctuation
                )
            )
            return
        }

        callbacks.onWaitingForFinalResultChanged(true)
        cloudEngine.stop { [weak self] recognizedText, errorMsg in
            guard let self else { return }
            DispatchQueue.main.async {
                callbacks.onWaitingForFinalResultChanged(false)
                if let errorMsg {
                    self.finishWithAppleFallback(
                        originalError: errorMsg,
                        fallbackTextIfAppleEmpty: recognizedText,
                        appending: nil,
                        callbacks: callbacks,
                        completion: completion
                    )
                } else {
                    self.fallback.finishSuccessfulCloudRecognition()
                    self.audioEngine.releaseHardwareAfterIdle()
                    completion(
                        RecognitionSessionStopResult(
                            text: recognizedText,
                            errorMessage: nil,
                            appendingImmediatePunctuation: nil
                        )
                    )
                }
            }
        }
    }

    func cancel() {
        usingAppleStartFallback = false
        let shouldStopAppleLiveFallback = fallback.cancel()
        cloudEngine.cancel()
        if shouldStopAppleLiveFallback {
            _ = speechRecognizerProvider().stop()
        }
        appleSession.cancel()
        unregisterConsumer()
    }

    private func handleRecognitionError(_ message: String, callbacks: RecognitionSessionCallbacks) {
        let isBenignSilenceError = appleLiveFallback.isBenignSilenceError(
            message,
            cloudCurrentText: cloudEngine.currentText
        )
        let visibleError = isBenignSilenceError ? "" : message
        guard fallback.recordError(visibleError, currentText: cloudEngine.currentText) else { return }

        DebugLog.error("[Session] 豆包识别错误: \(message)")
        cloudEngine.cancel()
        callbacks.onResetLiveInsertion()

        guard callbacks.isRecordingCurrent() else {
            if !isBenignSilenceError {
                callbacks.onError(loc("doubao.fallback.withError", message))
            }
            return
        }

        let initialText = appleLiveFallback.engage(onPartial: { merged in
            guard callbacks.isRecordingCurrent() else { return }
            callbacks.onPartialResult(merged, false)
        })
        guard let initialText else { return }

        DebugLog.info("[Session] 启动 Apple 实时回退 (豆包错误后)")
        callbacks.onEffectiveEngineChanged(ASREngineRegistry.appleCode)
        callbacks.onShimmerChanged(false)
        callbacks.onProgress(initialText, false)
        DebugLog.error("[Doubao] 识别失败，录音结束后将回退到 Apple Speech: \(message)")
    }

    private func consumeFallbackIfNeeded(
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks?,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) -> Bool {
        guard fallback.currentError != nil || fallback.isAppleLiveActive else {
            return false
        }
        cloudEngine.cancel()
        finishWithAppleFallback(
            originalError: fallback.currentError ?? "",
            fallbackTextIfAppleEmpty: "",
            appending: punctuation,
            callbacks: callbacks,
            completion: completion
        )
        return true
    }

    private func finishWithAppleFallback(
        originalError: String,
        fallbackTextIfAppleEmpty: String,
        appending punctuation: String?,
        callbacks: RecognitionSessionCallbacks?,
        completion: @escaping (RecognitionSessionStopResult) -> Void
    ) {
        let fallbackSnapshot = fallback.makeFallbackSnapshot(
            originalError: originalError,
            fallbackTextIfAppleEmpty: fallbackTextIfAppleEmpty,
            stopLiveFallback: { [weak self] in self?.speechRecognizerProvider().stop() ?? "" }
        )
        let trimmedOriginal = fallbackSnapshot.originalError.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackError = trimmedOriginal.isEmpty ? nil : loc("doubao.fallback.withError", trimmedOriginal)

        guard !fallbackSnapshot.buffers.isEmpty else {
            let text = DoubaoFallbackCoordinator.combinedText(
                prefix: fallbackSnapshot.cloudPrefixText,
                cachedText: "",
                liveText: fallbackSnapshot.liveFallbackText
            )
            audioEngine.releaseHardwareAfterIdle()
            completion(
                RecognitionSessionStopResult(
                    text: text,
                    errorMessage: text.isEmpty ? fallbackError : nil,
                    appendingImmediatePunctuation: punctuation
                )
            )
            return
        }

        callbacks?.onEffectiveEngineChanged(ASREngineRegistry.appleCode)
        callbacks?.onProgress(loc("menu.recognitionEngine.apple"), true)
        speechRecognizerProvider().recognize(buffers: fallbackSnapshot.buffers, onResult: { text, _ in
            DispatchQueue.main.async {
                guard callbacks?.isCurrent() ?? true else { return }
                let merged = DoubaoFallbackCoordinator.combinedText(
                    prefix: fallbackSnapshot.cloudPrefixText,
                    cachedText: text,
                    liveText: fallbackSnapshot.liveFallbackText
                )
                callbacks?.onPartialResult(merged, false)
            }
        }) { appleText in
            DispatchQueue.main.async {
                guard callbacks?.isCurrent() ?? true else { return }
                let recognizedText = DoubaoFallbackCoordinator.combinedText(
                    prefix: fallbackSnapshot.cloudPrefixText,
                    cachedText: appleText,
                    liveText: fallbackSnapshot.liveFallbackText
                )
                self.audioEngine.releaseHardwareAfterIdle()
                completion(
                    RecognitionSessionStopResult(
                        text: recognizedText,
                        errorMessage: recognizedText.isEmpty ? fallbackError : nil,
                        appendingImmediatePunctuation: punctuation
                    )
                )
            }
        }
    }

    private func unregisterConsumer() {
        if let id = activeRouterConsumerID {
            audioEngine.router.unregister(id)
            activeRouterConsumerID = nil
        }
    }
}
