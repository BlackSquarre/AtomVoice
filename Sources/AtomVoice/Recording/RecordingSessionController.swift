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
    #if DEBUG_BUILD
    private let audioEvidenceRecorder = DebugAudioEvidenceRecorder()
    #endif

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
    private let sherpaModelLoadingSilenceGrace: TimeInterval = 15
    /// 停止录音到收起胶囊的延迟（秒）：给一个极短缓冲，让胶囊消失不突兀。
    /// (Delay from stop to capsule dismissal — a tiny buffer so the capsule doesn't vanish abruptly.)
    private let stopCapsuleDismissDelay: TimeInterval = 0.1

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

    convenience init(
        audioEngine: AudioEngineController,
        capsuleWindow: CapsuleWindowController,
        llmRefiner: LLMRefiner,
        textPostProcessorRegistry: TextPostProcessorRegistry,
        textOutputSinkRegistry: TextOutputSinkRegistry,
        volumeController: VolumeController,
        asrEngineRegistry: ASREngineRegistry,
        asrEngineProvider: ASREngineProviding
    ) {
        let presenter = RecordingSessionPresenter(capsuleWindow: capsuleWindow)
        self.init(
            audioEngine: audioEngine,
            presenter: presenter,
            llmRefiner: llmRefiner,
            textPostProcessorRegistry: textPostProcessorRegistry,
            textOutputSinkRegistry: textOutputSinkRegistry,
            volumeController: volumeController,
            asrEngineRegistry: asrEngineRegistry,
            asrEngineProvider: asrEngineProvider
        )
    }

    init(
        audioEngine: AudioEngineController,
        presenter: RecordingSessionPresenting,
        llmRefiner: LLMRefiner,
        textPostProcessorRegistry: TextPostProcessorRegistry,
        textOutputSinkRegistry: TextOutputSinkRegistry,
        volumeController: VolumeController,
        asrEngineRegistry: ASREngineRegistry,
        asrEngineProvider: ASREngineProviding
    ) {
        self.audioEngine = audioEngine
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
        if text == loc("sherpa.loadingModel") {
            _ = dispatch(.silenceMonitorGraceRequested(duration: sherpaModelLoadingSilenceGrace))
        }
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
        _ = dispatch(
            .recognitionCapabilitiesResolved(
                mutableCapsulePreview: selectedSession.supportsMutableCapsulePreview
            )
        )

        let lowerVolume = AppSettings.lowerVolumeOnRecording
        DebugLog.info("[Session] startRecording: lowerVolume=\(lowerVolume)")
        #if DEBUG_BUILD
        audioEvidenceRecorder.reset()
        #endif
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
            selectedSession.start(
                audioFormat: selectedSession.preferredAudioFormat,
                callbacks: callbacks
            ) { [weak self] result in
                let handleResult = {
                    guard let self,
                          self.isRecording,
                          self.recordingGeneration == generation else { return }
                    switch result {
                    case .started:
                        self.dispatch(.sessionStartCompleted(generation: generation))
                    case .failed(let failure):
                        #if DEBUG_BUILD
                        self.preserveDebugAudioEvidence(reason: .sessionStartFailed)
                        #endif
                        self.dispatch(
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
                if Thread.isMainThread {
                    handleResult()
                } else {
                    DispatchQueue.main.async(execute: handleResult)
                }
            }
        }
    }

    // MARK: - 启动失败处理（Start-failure handlers）

    private func handleAudioRouteRecoveryFailed() {
        DebugLog.error("[Session] Audio route recovery failed, ending current recording")
        #if DEBUG_BUILD
        preserveDebugAudioEvidence(reason: .audioRouteRecoveryFailed)
        #endif
        _ = dispatch(.audioRouteRecoveryFailed)
    }

    #if DEBUG_BUILD
    func preserveDebugAudioEvidence(reason: DebugAudioEvidenceReason) {
        _ = audioEvidenceRecorder.preserve(reason: reason)
    }
    #endif

    // MARK: - 实时识别更新与状态（Real-time updates & state）

    private func cancelPendingStart() {
        audioEngine.cancelInputReadinessCheck()
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
        #if DEBUG_BUILD
        audioEvidenceRecorder.record(copy)
        #endif
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
        // 停止键按下即收起胶囊（仅非 LLM 路径）：识别收尾与上屏在后台继续，给用户即时反馈。
        // 开 LLM 时保留胶囊，用于展示"优化中"与优化结果。
        // (Dismiss the capsule the moment the stop key is pressed, on the non-LLM path; finalize and paste continue in the background.)
        dismissCapsuleOnStopIfNoRefinement()
    }

    /// 停止录音时若不会走 LLM 润色，延迟极短时间收起胶囊；识别收尾与上屏在后台继续。
    /// (On stop, if no LLM refinement will run, dismiss the capsule after a tiny delay; finalize/paste continue in background.)
    private func dismissCapsuleOnStopIfNoRefinement() {
        let willRefine = AppSettings.llmEnabled && !AppSettings.llmAPIKey.isEmpty
        guard !willRefine else { return }
        scheduleCapsuleDismissAfterStop()
    }

    /// 停止后收起胶囊：本地引擎停止即出结果，立即收起（上屏飞快）；
    /// 云端要等异步 final，延迟 stopCapsuleDismissDelay 再收起更柔和，并在期间开始新录音时跳过，避免误关新胶囊。
    /// (Dismiss the capsule on stop: local engines dismiss instantly; cloud engines delay slightly to avoid a flicker,
    ///  skipping if a new recording has started meanwhile.)
    private func scheduleCapsuleDismissAfterStop() {
        guard recognitionSession?.dismissCapsuleImmediatelyOnStop == false else {
            presenter.dismiss(completion: nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + stopCapsuleDismissDelay) { [weak self] in
            guard let self, !self.isRecordingOrStarting else { return }
            self.presenter.dismiss(completion: nil)
        }
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
        // 立即上屏路径跳过 LLM，延迟极短时间收起胶囊。
        // (Immediate-output path skips LLM; dismiss the capsule a tiny delay after stop.)
        scheduleCapsuleDismissAfterStop()
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
