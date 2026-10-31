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
    var recordingAudioInput = RecordingAudioInput()
    /// 仅在识别会话真正启动后才允许启动新会话前取消，避免 idle 状态重复排队 cancel。
    /// (Cancel before a new start only when the previous recognition session actually started.)
    var recognitionSessionStarted = false
    private var pendingLiveInsertionPresentationCompletions: [() -> Void] = []
    private var captureConsumerID: UUID?
    private var pendingPreparedSession: (any RecognitionSession)?
    private var pendingPrepareResult: RecognitionSessionPreflightResult?
    private var pendingCaptureReady: Bool?
    private var startPreflightEventEmitted = false
    var pendingStopForPresentation: Bool { pendingStop != nil }
    private var captureEngineCode: String?
    private var recognitionReady: Bool {
        get { state.recognitionReady }
        set { state.recognitionReady = newValue }
    }
    private var pendingStop: RecordingPreparationStop? {
        get { state.preparationStop }
        set { state.preparationStop = newValue }
    }
    private var captureRequestedAt = ProcessInfo.processInfo.systemUptime

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

    // MARK: - 协调器（Coordinators）
    let audioAnalyzer = AudioAnalyzer()
    let asrSilenceMonitor = ASRSilenceMonitor()
    private let capsuleAudioFrameDelivery = CapsuleAudioFrameDelivery()
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
            guard let self, self.isRecordingOrStarting, self.pendingStop == nil else { return }
            self.stop()
        }
        audioAnalyzer.onAnalysis = { [weak self] frame in
            guard let self else { return }
            // 判停保留每帧连续性；只有 UI 投递合并为最新帧。
            self.asrSilenceMonitor.noteVoiceActivity(isVoiceLike: frame.isVoiceLike, at: frame.capturedAt)
            self.capsuleAudioFrameDelivery.submit(frame) { [weak self] latest in
                guard let self, self.isRecordingOrStarting, self.pendingStop == nil,
                      latest.capturedAt >= self.captureRequestedAt else { return }
                self.updateCapsuleBands(latest.bands)
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
    var isRecordingOrStarting: Bool { (isRecording || isStarting) && pendingStop == nil }

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
        guard isRecordingOrStarting, pendingStop == nil, !state.deferredCapsule.isDeferred else { return }
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
        if pendingStop != nil {
            cancelRecording()
            pendingStop = nil
        }
        _ = dispatch(.triggerPressed(deferCapsulePresentation: deferCapsulePresentation))
    }

    func waitForInputReady(startRequest: Int) {
        captureRequestedAt = ProcessInfo.processInfo.systemUptime
        recordingAudioInput.cancel()
        recordingAudioInput = RecordingAudioInput()
        recognitionReady = false
        pendingStop = nil
        pendingLiveInsertionPresentationCompletions.removeAll()
        pendingPreparedSession = nil
        pendingPrepareResult = nil
        pendingCaptureReady = nil
        startPreflightEventEmitted = false
        if let id = captureConsumerID { audioEngine.router.unregister(id) }
        let input = recordingAudioInput
        captureEngineCode = AppSettings.normalizedRecognitionEngine
        let format: AudioRouter.ConsumerFormat? = captureEngineCode == ASREngineRegistry.appleCode ? nil : .voice16k
        captureConsumerID = audioEngine.router.register(format: format) { buffer in input.accept(buffer) }
        let selectedSession = recognitionSession(for: captureEngineCode ?? AppSettings.normalizedRecognitionEngine)
        pendingPreparedSession = selectedSession
        selectedSession.prepare { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state.acceptsStartRequest(startRequest),
                      self.pendingPreparedSession === selectedSession else { return }
                self.pendingPrepareResult = result
                self.emitStartPreflightIfReady(request: startRequest)
            }
        }
        // 音频设备启动和 ASR prepare 并行执行；两者都完成后才进入 startValidated。
        audioEngine.start { [weak self] ready in
            guard let self, self.state.acceptsStartRequest(startRequest) else { return }
            DebugLog.info("[RecordingLatency] capture ready ms=\((ProcessInfo.processInfo.systemUptime - self.captureRequestedAt) * 1000)")
            self.pendingCaptureReady = ready || self.pendingStop != nil
            self.emitStartPreflightIfReady(request: startRequest)
            if !ready && self.pendingStop == nil {
                self.stopCapture()
                self.onRecordingStateChanged?(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.startRequestGeneration == startRequest,
                  self.state.isRecordingOrStarting, !self.recognitionReady else { return }
            self.stopCapture()
            self.recordingAudioInput.cancel()
            self.onRecordingStateChanged?(false)
            if self.isStarting {
                self.dispatch(.startPreflightFailed(message: loc("cloudASR.error.timeout"), ensurePanel: true))
            } else {
                self.dispatch(.sessionStartFailed(message: loc("cloudASR.error.timeout"), dismissAfter: 5,
                                                 stopAudioEngine: true, recovery: nil))
            }
        }
        onRecordingStateChanged?(true)
        showInitialCapsule()
        DebugLog.info("[RecordingLatency] initial UI submitted ms=\((ProcessInfo.processInfo.systemUptime - captureRequestedAt) * 1000)")
    }

    private func emitStartPreflightIfReady(request: Int) {
        guard !startPreflightEventEmitted,
              let captureReady = pendingCaptureReady else { return }
        if !captureReady {
            startPreflightEventEmitted = true
            dispatch(.inputPreflightCompleted(request: request, ready: false))
            return
        }
        guard pendingPrepareResult != nil else { return }
        startPreflightEventEmitted = true
        dispatch(.inputPreflightCompleted(request: request, ready: true))
    }

    func stopCapture() {
        recordingAudioInput.seal()
        if let id = captureConsumerID {
            audioEngine.router.unregister(id)
            captureConsumerID = nil
        }
        audioEngine.stop()
        audioEngine.releaseHardwareAfterIdle()
    }

    func continueStartRecording(startRequest: Int) {
        guard state.acceptsStartRequest(startRequest) else { return }
        // Sherpa 引擎：直接按当前 preset 实读磁盘判断；isReady 内部含一次轻量自愈
        // (Sherpa engine: read disk for current preset; isReady includes one lightweight self-heal pass)
        let engine = captureEngineCode ?? AppSettings.normalizedRecognitionEngine
        let selectedSession = pendingPreparedSession ?? recognitionSession(for: engine)
        if pendingPreparedSession === selectedSession {
            guard let result = pendingPrepareResult else { return }
            pendingPreparedSession = nil
            pendingPrepareResult = nil
            completeStartPreflight(result, selectedSession: selectedSession)
        } else {
            selectedSession.prepare { [weak self] result in
                guard let self, self.state.acceptsStartRequest(startRequest) else { return }
                self.completeStartPreflight(result, selectedSession: selectedSession)
            }
        }
    }

    private func completeStartPreflight(_ result: RecognitionSessionPreflightResult, selectedSession: any RecognitionSession) {
        switch result {
        case .ready:
            break
        case .requestExternalDownload(let redownload):
            stopCapture()
            onRecordingStateChanged?(false)
            recordingAudioInput.cancel()
            presenter.dismiss(completion: nil)
            _ = dispatch(.externalModelDownloadRequired(redownload: redownload))
            return
        case .waitForExternalDownload:
            stopCapture()
            onRecordingStateChanged?(false)
            recordingAudioInput.cancel()
            presenter.dismiss(completion: nil)
            _ = dispatch(.externalModelDownloadInProgress)
            return
        case .failure(let error):
            stopCapture()
            onRecordingStateChanged?(false)
            recordingAudioInput.cancel()
            _ = dispatch(.startPreflightFailed(message: error, ensurePanel: true))
            return
        }

        let pendingDoubaoText = state.isWaitingForDoubaoFinalResult
            ? recognitionSession?.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let pendingRefinementText = state.isRefining ? state.pendingRefinementText : nil
        if recognitionSession !== selectedSession {
            recognitionSession?.cancel()
            recognitionSessionStarted = false
        }
        recognitionSession = selectedSession
        _ = dispatch(
            .recognitionCapabilitiesResolved(
                mutableCapsulePreview: selectedSession.supportsMutableCapsulePreview
            )
        )

        let lowerVolume = AppSettings.lowerVolumeOnRecording && pendingStop == nil
        DebugLog.info("[Session] startRecording: lowerVolume=\(lowerVolume)")
        #if DEBUG_BUILD
        audioEvidenceRecorder.reset()
        #endif
        _ = dispatch(
            .startValidated(
                engine: selectedSession.code,
                pendingDoubaoText: pendingDoubaoText,
                pendingRefinementText: pendingRefinementText,
                lowerVolume: lowerVolume
            )
        )
    }

    func startRecognitionSession(generation: Int) {
        guard let selectedSession = recognitionSession else { return }
        let start = { [weak self] in
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
                        self.recognitionSessionStarted = true
                        self.recognitionReady = true
                        if let stop = self.pendingStop {
                            self.pendingStop = nil
                            self.completeDeferredStop(stop)
                        } else {
                            self.dispatch(.sessionStartCompleted(generation: generation))
                        }
                    case .failed(let failure):
                        #if DEBUG_BUILD
                        self.preserveDebugAudioEvidence(reason: .sessionStartFailed)
                        #endif
                        self.dispatch(
                            .sessionStartFailed(
                                message: failure.message,
                                dismissAfter: failure.dismissAfter,
                                stopAudioEngine: true,
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
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
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
        stopCapture()
        onRecordingStateChanged?(false)
        recordingAudioInput.cancel()
        pendingStop = nil
        pendingLiveInsertionPresentationCompletions.removeAll()
        presenter.dismiss(completion: nil)
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
        if deferStopIfPreparing(immediate: false, punctuation: nil) { return }
        guard isRecording else {
            if isStarting { cancelPendingStart() }
            return
        }
        stopCapture()
        _ = dispatch(.triggerReleased)
    }

    private func cancelRecording() {
        guard isRecording || isRefining || state.phase == .stopping else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        
        _ = dispatch(.cancelRequested)
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入。
    /// (Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly.)
    private func stopRecordingImmediate(appending punctuation: String? = nil) {
        if deferStopIfPreparing(immediate: true, punctuation: punctuation) { return }
        guard isRecording else {
            if isStarting { cancelPendingStart() }
            return
        }
        stopCapture()
        _ = dispatch(.immediateStop(appending: punctuation))
    }

    private func deferStopIfPreparing(immediate: Bool, punctuation: String?) -> Bool {
        guard state.isRecordingOrStarting, !recognitionReady else { return false }
        guard pendingStop == nil else { return true }
        pendingStop = RecordingPreparationStop(immediate: immediate, punctuation: punctuation)
        stopCapture()
        asrSilenceMonitor.stop()
        onRecordingStateChanged?(false)
        volumeController.restoreVolume()
        resetDeferredCapsulePresentation()
        presenter.present(.showOptimizing)
        return true
    }

    private func completeDeferredStop(_ stop: RecordingPreparationStop) {
        dispatch(stop.immediate ? .immediateStop(appending: stop.punctuation) : .triggerReleased)
    }

    func stopRecognitionSession(generation: Int, immediate: Bool, appending punctuation: String?) {
        guard let session = recognitionSession else { return }
        stopCapture()
        presenter.present(.showOptimizing)
        let callbacks = makeRecognitionSessionCallbacks(generation: generation)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        var didFinish = false
        recordingAudioInput.finish { [weak self] in
            guard let self, self.recordingGeneration == generation else { return }
            session.stop(immediate: immediate, appending: punctuation, callbacks: callbacks) { [weak self] result in
                guard let self, self.recordingGeneration == generation, !didFinish else { return }
                didFinish = true
                self.recognitionSessionStarted = false
                DebugLog.info("[RecordingLatency] final decode ms=\((ProcessInfo.processInfo.systemUptime - stoppedAt) * 1000)")
                self.dispatch(.asrFinal(text: result.text, errorMessage: result.errorMessage,
                                       appending: result.appendingImmediatePunctuation))
                // 余下文本立即进入输出队列；只让呈现收尾等待在途实时上屏，避免下一轮开始丢掉尾文。
                self.finishRecognizedResult(result.text, errorMsg: result.errorMessage,
                                            immediate: immediate, appending: result.appendingImmediatePunctuation)
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

    private func finishRecognizedResult(_ text: String, errorMsg: String? = nil, immediate: Bool, appending punctuation: String? = nil) {
        if immediate {
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
        let generation = recordingGeneration
        let finalizingStream = streamSession
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
                streamSession: finalizingStream,
                clearStreamSession: { [weak self] in
                    guard let self, self.recordingGeneration == generation,
                          self.streamSession === finalizingStream else { return }
                    self.streamSession = nil
                },
                generation: generation,
                waitForPriorOutput: { [weak self] completion in
                    guard let self, self.recordingGeneration == generation else { return }
                    if self.state.liveInsertion.pasteInFlight {
                        self.pendingLiveInsertionPresentationCompletions.append(completion)
                    } else {
                        completion()
                    }
                }
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
        let generation = recordingGeneration
        activeOutputSink.deliver(text: decision.segment) { [weak self] in
            guard let self, self.recordingGeneration == generation else { return }
            self.dispatch(.liveInsertionCommitFinished)
            let presentationCompletions = self.pendingLiveInsertionPresentationCompletions
            self.pendingLiveInsertionPresentationCompletions.removeAll()
            presentationCompletions.forEach { $0() }
            if self.isRecording {
                self.commitAppleLiveSegmentIfNeeded(from: self.state.liveInsertion.latestText, isFinal: false)
            }
        }
    }
}
