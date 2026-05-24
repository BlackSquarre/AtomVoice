import Cocoa
import AVFoundation

/// 录音会话委托：Session 通过它触发外部 Sherpa 下载流程，并通知录音结束。
/// (Recording session delegate: Session uses it to trigger external Sherpa download flow and notify recording end.)
protocol RecordingSessionDelegate: AnyObject {
    func sessionRequiresSherpaModelDownload(redownload: Bool)
    func sessionDidEnd()
}

/// 录音状态机：从 Fn 按下到识别结果上屏的全部流水线。
/// (Recording state machine: full pipeline from Fn press through recognition delivery.)
final class RecordingSessionController {
    // MARK: - 依赖（Dependencies）
    let audioEngine: AudioEngineController
    let presenter: RecordingSessionPresenting
    let llmRefiner: LLMRefiner
    private let textOutputSinkRegistry: TextOutputSinkRegistry
    let volumeController: VolumeController
    private let asrEngineProvider: ASREngineProviding
    private let recognitionFinalizer: RecognitionResultFinalizer
    private let liveInsertionAdapter = AppleLiveInsertionAdapter()
    var recognitionSession: (any RecognitionSession)?
    weak var delegate: RecordingSessionDelegate?

    /// 录音中状态变化回调：true=进入录音，false=结束（用于同步外部组件如 FnKeyMonitor.isRecording）。
    /// (Recording-active state callback: true on enter, false on stop. Used to sync external components like FnKeyMonitor.isRecording.)
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onRefiningStateChanged: ((Bool) -> Void)?

    // MARK: - 状态（State）
    var state = RecordingSessionState()
    var streamSession: TextStreamSession?
    var isRecording: Bool { state.isRecording }
    var isRefining: Bool { state.isRefining }
    private var isStarting: Bool { state.isStarting }
    private(set) var currentRecordingEngine: String {
        get { state.currentRecordingEngine }
        set { state.currentRecordingEngine = newValue }
    }
    var recordingGeneration: Int {
        get { state.recordingGeneration }
    }
    private var startRequestGeneration: Int {
        get { state.startRequestGeneration }
    }

    // MARK: - 协调器（Coordinators）
    let audioAnalyzer = AudioAnalyzer()
    let asrSilenceMonitor = ASRSilenceMonitor()
    /// AudioAnalyzer 订阅 router 16kHz 的消费者 ID；session 整体 deinit 时注销。
    /// (Analyzer's router consumer; unregistered on session deinit.)
    private var analyzerConsumerID: UUID?

    // MARK: - 计算属性（Computed）
    var activeOutputSink: TextOutputSink { textOutputSinkRegistry.current() }
    var streamingCompactKey: String? {
        streamSession != nil ? "capsule.streaming.typing" : nil
    }
    var activeRecognitionSession: (any RecognitionSession)? {
        recognitionSession
    }
    private func recognitionSession(for code: String) -> any RecognitionSession {
        asrEngineProvider.recognitionSession(for: code, audioEngine: audioEngine)
    }

    init(
        audioEngine: AudioEngineController,
        capsuleWindow: CapsuleWindowController,
        llmRefiner: LLMRefiner,
        textPostProcessorRegistry: TextPostProcessorRegistry,
        textOutputSinkRegistry: TextOutputSinkRegistry,
        volumeController: VolumeController,
        asrEngineRegistry: ASREngineRegistry,
        asrEngineProvider: ASREngineProviding
    ) {
        self.audioEngine = audioEngine
        let presenter = RecordingSessionPresenter(capsuleWindow: capsuleWindow)
        self.presenter = presenter
        self.llmRefiner = llmRefiner
        self.textOutputSinkRegistry = textOutputSinkRegistry
        self.volumeController = volumeController
        self.asrEngineProvider = asrEngineProvider
        let finalizer = RecognitionResultFinalizer(
            presenter: presenter,
            refiner: llmRefiner,
            textPostProcessorRegistry: textPostProcessorRegistry,
            outputSinkProvider: { textOutputSinkRegistry.current() },
            settingsProvider: {
                RecognitionResultFinalizer.Settings(
                    language: AppSettings.selectedLanguage,
                    llmEnabled: AppSettings.llmEnabled,
                    llmAPIKey: AppSettings.llmAPIKey,
                    llmResultDelay: AppSettings.llmResultDelay
                )
            }
        )
        self.recognitionFinalizer = finalizer
        
        finalizer.onRefiningStateChanged = { [weak self] refining, text in
            guard let self else { return }
            if refining {
                self.dispatch(.refiningStarted(text: text))
            } else {
                self.dispatch(.refiningFinished)
            }
        }
        finalizer.currentGenerationProvider = { [weak self] in
            self?.recordingGeneration ?? -1
        }

        // AudioAnalyzer 永久订阅 router 16kHz 通道：tap 装上才会有 buffer，不录音期间零开销。
        // (Permanent 16kHz subscription; analyzer only sees buffers when tap is installed.)
        analyzerConsumerID = audioEngine.router.register(format: .voice16k) { [weak self] buffer in
            self?.audioAnalyzer.accept(buffer)
        }
        asrSilenceMonitor.onTimeout = { [weak self] in
            self?.stop()
        }
        audioAnalyzer.onBands = { [weak self] bands in
            DispatchQueue.main.async {
                self?.updateCapsuleBands(bands)
            }
        }
        audioEngine.onRouteRecoveryFailed = { [weak self] in
            self?.handleAudioRouteRecoveryFailed()
        }
    }

    deinit {
        if let id = analyzerConsumerID {
            audioEngine.router.unregister(id)
        }
    }

    // MARK: - 公开 API（Public API）

    func start() { startRecording() }
    func startDeferringCapsulePresentation() { startRecording(deferCapsulePresentation: true) }
    func revealDeferredCapsulePresentation() { revealDeferredRecordingPresentation() }
    func stop() { stopRecording() }
    func stopImmediate(appending punctuation: String?) { stopRecordingImmediate(appending: punctuation) }
    func cancel() { cancelRecording() }

    /// 当前是否正在显示错误胶囊（Whether the error capsule is currently showing）
    var isShowingError: Bool { presenter.isShowingError }

    /// 录音已经开始，或正在等待异步输入设备 preflight 完成。
    /// (Recording has started, or the async input preflight is still pending.)
    var isRecordingOrStarting: Bool { isRecording || isStarting }

    /// 关闭错误胶囊（Dismiss the error capsule）
    func dismissError() { presenter.dismiss(completion: nil) }

    // MARK: - 胶囊延迟呈现（Deferred capsule presentation）

    private func resetDeferredCapsulePresentation() {
        state.deferredCapsule.reset()
    }

    func activateTextOutputForRecordingIfNeeded() {
        guard isRecording, !state.textOutputActivated else { return }
        if activeOutputSink.descriptor.supportsStreaming {
            streamSession = activeOutputSink.beginStream()
        }
        let liveInsertionActive = streamSession == nil &&
            (recognitionSession?.supportsLiveInsertion == true) &&
            AppSettings.appleLiveInsertionEnabled &&
            !AppSettings.llmEnabled
        let result = RecordingStateMachine.reduce(state, .textOutputActivated(liveInsertion: liveInsertionActive))
        state = result.state
        execute(result.sideEffects)
    }

    private func revealDeferredRecordingPresentation() {
        guard state.deferredCapsule.isDeferred else { return }

        let presentation = state.deferredCapsule.pendingPresentation
        let shouldApplyShimmer = state.deferredCapsule.pendingShimmer
        let recognizedText = state.deferredCapsule.recognizedText
        let liveInsertionText = state.deferredCapsule.liveInsertionText
        let liveInsertionIsFinal = state.deferredCapsule.liveInsertionIsFinal

        _ = dispatch(.deferredCapsuleReveal)

        let events = RecordingSessionPresentationEvent.revealEvents(
            for: presentation,
            isRecording: isRecording,
            compactStatusKey: streamingCompactKey
        )
        events.forEach { presenter.present($0) }

        if shouldApplyShimmer {
            presenter.present(.startShimmer)
        }
        if let recognizedText {
            _ = dispatch(.asrPartial(text: recognizedText, isFinal: false))
        }
        if let liveInsertionText {
            commitAppleLiveSegmentIfNeeded(from: liveInsertionText, isFinal: liveInsertionIsFinal)
        }
    }

    func showInitialCapsule() {
        _ = dispatch(.capsulePresentationRequested(.initial))
    }

    func showRecordingCapsule() {
        _ = dispatch(.capsulePresentationRequested(.recording))
    }

    func showCapsuleProgress(_ text: String, hidesWaveform: Bool = true) {
        _ = dispatch(.capsulePresentationRequested(.progress(text: text, hidesWaveform: hidesWaveform)))
    }

    func showCapsuleError(_ message: String, dismissAfter delay: TimeInterval, ensurePanel: Bool = false) {
        if state.deferredCapsule.isDeferred {
            _ = dispatch(.capsulePresentationRequested(.error(message: message, dismissAfter: delay)))
        } else {
            presentCapsule(.error(message: message, dismissAfter: delay), ensurePanel: ensurePanel)
        }
    }

    func updateCapsuleText(_ text: String) {
        _ = dispatch(.capsuleTextUpdated(text))
    }

    private func updateCapsuleBands(_ bands: [Float]) {
        guard !state.deferredCapsule.isDeferred else { return }
        presenter.present(.updateBands(bands))
    }

    func applyCapsuleShimmer() {
        _ = dispatch(.shimmerChanged(true))
    }

    func stopCapsuleShimmer() {
        _ = dispatch(.shimmerChanged(false))
    }

    // MARK: - 录音启动（Recording start）

    private func startRecording(deferCapsulePresentation: Bool = false) {
        _ = dispatch(.triggerPressed(deferCapsulePresentation: deferCapsulePresentation))
    }

    func waitForInputReady(startRequest: Int) {
        audioEngine.waitForInputReady(timeout: 0.5) { [weak self] ready in
            guard let self else { return }
            guard self.isStarting,
                  self.startRequestGeneration == startRequest,
                  !self.isRecording else { return }
            self.dispatch(.inputPreflightCompleted(request: startRequest, ready: ready))
        }
    }

    func continueStartRecording(startRequest: Int) {
        guard state.acceptsStartRequest(startRequest) else { return }
        // Sherpa 引擎：直接按当前 preset 实读磁盘判断；isReady 内部含一次轻量自愈
        // (Sherpa engine: read disk for current preset; isReady includes one lightweight self-heal pass)
        let engine = AppSettings.normalizedRecognitionEngine
        let selectedSession = recognitionSession(for: engine)
        switch selectedSession.preflight() {
        case .ready:
            break
        case .requestExternalDownload(let redownload):
            _ = dispatch(.externalModelDownloadRequired(redownload: redownload))
            return
        case .waitForExternalDownload:
            _ = dispatch(.externalModelDownloadInProgress)
            return
        case .failure(let error):
            _ = dispatch(.startPreflightFailed(message: error, ensurePanel: true))
            return
        }

        let pendingDoubaoText = state.isWaitingForDoubaoFinalResult
            ? recognitionSession?.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let pendingRefinementText = state.isRefining ? state.pendingRefinementText : nil
        recognitionSession = selectedSession

        let lowerVolume = AppSettings.lowerVolumeOnRecording
        DebugLog.info("[Session] startRecording: lowerVolume=\(lowerVolume)")
        _ = dispatch(
            .startValidated(
                engine: AppSettings.normalizedRecognitionEngine,
                pendingDoubaoText: pendingDoubaoText,
                pendingRefinementText: pendingRefinementText,
                lowerVolume: lowerVolume
            )
        )
    }

    func startRecognitionSession(generation: Int) {
        guard let selectedSession = recognitionSession else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, isRecording, recordingGeneration == generation else { return }
            let callbacks = makeRecognitionSessionCallbacks(generation: generation)
            switch selectedSession.start(audioFormat: selectedSession.preferredAudioFormat, callbacks: callbacks) {
            case .started:
                break
            case .failed(let failure):
                dispatch(
                    .sessionStartFailed(
                        message: failure.message,
                        dismissAfter: failure.dismissAfter,
                        stopAudioEngine: failure.stopAudioEngine,
                        recovery: failure.recovery.map {
                            switch $0 {
                            case .requestSherpaModelDownload(let redownload, let delay):
                                return .requestSherpaModelDownload(redownload: redownload, delay: delay)
                            }
                        }
                    )
                )
            }
        }
    }

    // MARK: - 启动失败处理（Start-failure handlers）

    private func handleAudioRouteRecoveryFailed() {
        DebugLog.error("[Session] Audio route recovery failed, ending current recording")
        _ = dispatch(.audioRouteRecoveryFailed)
    }

    // MARK: - 实时识别更新与状态（Real-time updates & state）

    private func cancelPendingStart() {
        _ = dispatch(.cancelRequested)
    }

    func copyAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else { continue }
            let byteSize = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteSize)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }

    // MARK: - 录音收尾（Recording stop / cancel / immediate）

    private func stopRecording() {
        guard isRecording else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        _ = dispatch(.triggerReleased)
    }

    private func cancelRecording() {
        guard isRecording || isRefining else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        
        _ = dispatch(.cancelRequested)
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入。
    /// (Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly.)
    private func stopRecordingImmediate(appending punctuation: String? = nil) {
        guard isRecording else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        _ = dispatch(.immediateStop(appending: punctuation))
    }

    func stopRecognitionSession(generation: Int, immediate: Bool, appending punctuation: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.recognitionSession else { return }
            session.stop(
                immediate: immediate,
                appending: punctuation,
                callbacks: self.makeRecognitionSessionCallbacks(generation: generation)
            ) { [weak self] result in
                guard let self, self.recordingGeneration == generation else { return }
                self.dispatch(
                    .asrFinal(
                        text: result.text,
                        errorMessage: result.errorMessage,
                        appending: result.appendingImmediatePunctuation
                    )
                )
                self.finishRecognizedResult(
                    result.text,
                    errorMsg: result.errorMessage,
                    appending: result.appendingImmediatePunctuation
                )
            }
        }
    }

    private func finishRecording(with recognizedText: String, errorMsg: String? = nil) {
        defer { delegate?.sessionDidEnd() }
        finalizeRecognizedResult(recognizedText, mode: .normal, errorMsg: errorMsg)
    }

    private func finishImmediateRecording(with recognizedText: String, appending punctuation: String?, errorMsg: String? = nil) {
        defer { delegate?.sessionDidEnd() }
        finalizeRecognizedResult(recognizedText, mode: .immediate(appending: punctuation), errorMsg: errorMsg)
    }

    private func finishRecognizedResult(_ text: String, errorMsg: String? = nil, appending punctuation: String? = nil) {
        if punctuation != nil {
            finishImmediateRecording(with: text, appending: punctuation, errorMsg: errorMsg)
        } else {
            finishRecording(with: text, errorMsg: errorMsg)
        }
    }

    private func finalizeRecognizedResult(
        _ text: String,
        mode: RecognitionFinalizationMode,
        errorMsg: String?
    ) {
        recognitionFinalizer.finish(
            RecognitionResultFinalizer.Request(
                recognizedText: text,
                errorMessage: errorMsg,
                mode: mode,
                engineCode: currentRecordingEngine,
                liveInsertion: RecognitionLiveInsertionSnapshot(
                    isActive: state.liveInsertion.isActive,
                    committedText: state.liveInsertion.committedText
                ),
                streamSession: streamSession,
                clearStreamSession: { [weak self] in
                    self?.streamSession = nil
                },
                generation: recordingGeneration
            )
        )
    }

    // MARK: - Apple live insertion 段落提交（Apple live segment commit）

    func commitAppleLiveSegmentIfNeeded(from text: String, isFinal: Bool) {
        if state.deferredCapsule.isDeferred {
            _ = dispatch(.liveInsertionDeferred(text: text, isFinal: isFinal))
            return
        }
        guard state.liveInsertion.isActive,
              isRecording,
              recognitionSession?.supportsLiveInsertion == true
        else { return }
        _ = dispatch(.liveInsertionLatestObserved(text: text))
        guard !state.liveInsertion.pasteInFlight else { return }
        guard let decision = liveInsertionAdapter.nextCommitDecision(
            latestPartial: text,
            committedText: state.liveInsertion.committedText,
            isFinal: isFinal
        ) else { return }

        _ = dispatch(.liveInsertionCommitted(segment: decision.segment, latestText: text))
        activeOutputSink.deliver(text: decision.segment) { [weak self] in
            guard let self else { return }
            self.dispatch(.liveInsertionCommitFinished)
            if self.isRecording {
                self.commitAppleLiveSegmentIfNeeded(from: self.state.liveInsertion.latestText, isFinal: false)
            }
        }
    }
}
