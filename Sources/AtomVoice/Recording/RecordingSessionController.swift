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
    private var finalizations: [RecordingFinalization] = []
    private let recognitionFinalizer: RecognitionResultFinalizer
    private var liveInsertionDelivery = LiveInsertionDelivery()
    private let liveInsertionAdapter = AppleLiveInsertionAdapter()
    var recognitionSession: (any RecognitionSession)?
    var recordingAudioInput = RecordingAudioInput()
    /// 记录已提交与已启动的识别任务，取消覆盖准备中任务，idle 不重复取消。
    var recognitionSessionStarting = false
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
    }
    private var pendingStop: RecordingPreparationStop? {
        get { state.preparationStop }
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
    var currentRecordingEngine: String {
        get { state.currentRecordingEngine }
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
                let connection = AppSettings.llmConnection
                return RecognitionResultFinalizer.Settings(
                    language: AppSettings.selectedLanguage,
                    llmEnabled: AppSettings.llmEnabled,
                    llmAPIKey: connection.apiKey,
                    llmResultDelay: AppSettings.llmResultDelay,
                    autoPunctuationEnabled: AppSettings.autoPunctuationEnabled,
                    llmConnection: connection,
                    llmSystemPrompt: AppSettings.llmSystemPrompt
                )
            }
        )
        self.recognitionFinalizer = finalizer
        
        finalizer.onRefiningStateChanged = { [weak self] refining, _ in
            guard let self else { return }
            if refining {
                self.dispatch(.refiningStarted)
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
        dispatch(.deferredCapsuleReset)
    }

    func activateTextOutputForRecordingIfNeeded() {
        guard isRecording, !state.textOutputActivated else { return }
        if activeOutputSink.descriptor.supportsStreaming {
            streamSession = activeOutputSink.beginStream()
        }
        liveInsertionDelivery = LiveInsertionDelivery()
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

    func recognitionPreparationStageChanged(_ stage: RecognitionPreparationStage) {
        switch stage {
        case .loadingModel:
            dispatch(.silenceMonitorGraceRequested(duration: sherpaModelLoadingSilenceGrace))
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
        }
        _ = dispatch(.triggerPressed(deferCapsulePresentation: deferCapsulePresentation))
    }

    func waitForInputReady(startRequest: Int) {
        captureRequestedAt = ProcessInfo.processInfo.systemUptime
        if !finalizations.contains(where: { $0.audioInput === recordingAudioInput && $0.isOutputValid }) {
            recordingAudioInput.cancel()
        }
        recordingAudioInput = RecordingAudioInput()
        pendingLiveInsertionPresentationCompletions.removeAll()
        pendingPreparedSession = nil
        pendingPrepareResult = nil
        pendingCaptureReady = nil
        startPreflightEventEmitted = false
        if let id = captureConsumerID { audioEngine.router.unregister(id) }
        let input = recordingAudioInput
        captureEngineCode = AppSettings.normalizedRecognitionEngine
        let selectedSession = recognitionSession(for: captureEngineCode ?? AppSettings.normalizedRecognitionEngine)
        captureConsumerID = audioEngine.router.register(format: selectedSession.preferredAudioFormat) { buffer in input.accept(buffer) }
        pendingPreparedSession = selectedSession
        // 先提交收音，再并行准备 ASR；两者都完成后才进入 startValidated。
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
        selectedSession.prepare { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state.acceptsStartRequest(startRequest),
                      self.pendingPreparedSession === selectedSession else { return }
                self.pendingPrepareResult = result
                self.emitStartPreflightIfReady(request: startRequest)
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
        // 准备结果属于本次请求；资源检查及显式补缺由 session 的 prepare 承担。
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

        // 先采集、先准备；只在复用同一识别资源前等待原轮 stop 屏障。
        if let pending = finalizations.first(where: {
            $0.isRecognitionPending && !$0.resources.isDisjoint(with: selectedSession.recognitionResources)
        }) {
            let request = startRequestGeneration
            pending.whenRecognitionFinished { [weak self] in
                guard let self, self.state.acceptsStartRequest(request) else { return }
                self.completeStartPreflight(.ready, selectedSession: selectedSession)
            }
            return
        }
        if recognitionSession !== selectedSession {
            let priorResources = recognitionSession?.recognitionResources ?? []
            if !finalizations.contains(where: { $0.isRecognitionPending && !$0.resources.isDisjoint(with: priorResources) }) {
                recognitionSession?.cancel()
            }
            recognitionSessionStarted = false
            recognitionSessionStarting = false
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
                lowerVolume: lowerVolume
            )
        )
    }

    func startRecognitionSession(generation: Int) {
        guard let selectedSession = recognitionSession else { return }
        let start = { [weak self] in
            guard let self, isRecording, recordingGeneration == generation else { return }
            let callbacks = makeRecognitionSessionCallbacks(generation: generation)
            recognitionSessionStarting = true
            selectedSession.start(
                callbacks: callbacks
            ) { [weak self] result in
                let handleResult = {
                    guard let self,
                          self.isRecording,
                          self.recordingGeneration == generation else { return }
                    switch result {
                    case .started:
                        self.recognitionSessionStarting = false
                        self.recognitionSessionStarted = true
                        self.dispatch(.sessionStartCompleted(generation: generation))
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
        recognitionFinalizer.discardPendingRefinement()
        let cancelling = finalizations.filter { $0.generation == recordingGeneration }
        cancelling.forEach { $0.cancel() }
        finalizations.removeAll { !$0.isRecognitionPending }
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
        dispatch(.preparationStopRequested(.init(immediate: immediate, punctuation: punctuation)))
        stopCapture()
        asrSilenceMonitor.stop()
        onRecordingStateChanged?(false)
        volumeController.restoreVolume()
        resetDeferredCapsulePresentation()
        presenter.present(.showOptimizing)
        return true
    }

    func finishPendingRefinement() {
        recognitionFinalizer.finishPendingRefinement()
    }

    func stopRecognitionSession(generation: Int, immediate: Bool, appending punctuation: String?) {
        guard let session = recognitionSession else { return }
        stopCapture()
        presenter.present(.showOptimizing)
        let input = recordingAudioInput
        let context = RecordingFinalization(
            generation: generation, audioInput: input, resources: session.recognitionResources, engineCode: currentRecordingEngine,
            liveInsertion: .init(isActive: state.liveInsertion.isActive,
                                 committedText: state.liveInsertion.committedText, delivery: liveInsertionDelivery),
            streamSession: streamSession, settings: recognitionFinalizer.captureSettings(), outputSink: activeOutputSink)
        finalizations.append(context)
        let callbacks = makeRecognitionSessionCallbacks(generation: generation, finalization: context, audioInput: input)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        input.finish { [weak self] in
            guard let self, context.isOutputValid, context.isRecognitionPending else { return }
            session.stop(immediate: immediate, appending: punctuation, callbacks: callbacks) { [weak self] result in
                guard let self, context.isOutputValid, context.completeRecognition() else { return }
                if self.recognitionSession === session {
                    self.recognitionSessionStarted = false
                    self.recognitionSessionStarting = false
                }
                DebugLog.info("[RecordingLatency] final decode ms=\((ProcessInfo.processInfo.systemUptime - stoppedAt) * 1000)")
                if self.recordingGeneration == generation {
                    self.dispatch(.asrFinal(text: result.text, errorMessage: result.errorMessage,
                                           appending: result.appendingImmediatePunctuation))
                }
                self.finalizeRecognizedResult(result, immediate: immediate, context: context)
                self.delegate?.sessionDidEnd()
                context.releaseRecognitionWaiters()
            }
        }
    }

    private func finalizeRecognizedResult(_ result: RecognitionSessionStopResult, immediate: Bool,
                                          context: RecordingFinalization) {
        let finalizingStream = context.streamSession
        var request = RecognitionResultFinalizer.Request(
            recognizedText: result.text, errorMessage: result.errorMessage,
            mode: immediate ? .immediate(appending: result.appendingImmediatePunctuation) : .normal,
            engineCode: context.engineCode, liveInsertion: context.liveInsertion,
            streamSession: finalizingStream,
            clearStreamSession: { [weak self] in
                guard let self, self.recordingGeneration == context.generation,
                      self.streamSession === finalizingStream else { return }
                self.streamSession = nil
            }, generation: context.generation,
            waitForPriorOutput: { [weak self] completion in
                guard let self, self.recordingGeneration == context.generation else { return }
                if self.state.liveInsertion.pasteInFlight {
                    self.pendingLiveInsertionPresentationCompletions.append(completion)
                } else { completion() }
            })
        request.isOutputValid = { context.isOutputValid }
        request.settingsSnapshot = context.settings
        request.outputSink = context.outputSink
        request.onFinished = { [weak self] in self?.finalizations.removeAll { $0 === context } }
        recognitionFinalizer.finish(request)
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

        _ = dispatch(.liveInsertionCommitStarted)
        let delivery = liveInsertionDelivery
        delivery.begin(decision.segment)
        let generation = recordingGeneration
        activeOutputSink.deliver(text: decision.segment, onSubmission: { [weak self] submission in
            guard delivery.resolve(.init(submission: submission, cleanup: .notNeeded)) else { return }
            guard let self, self.recordingGeneration == generation else { return }
            if submission == .eventPosted {
                self.dispatch(.liveInsertionCommitted(segment: decision.segment, latestText: self.state.liveInsertion.latestText))
            }
        }) { [weak self] result in
            guard let self, self.recordingGeneration == generation else { return }
            self.dispatch(.liveInsertionCommitFinished)
            let presentationCompletions = self.pendingLiveInsertionPresentationCompletions
            self.pendingLiveInsertionPresentationCompletions.removeAll()
            presentationCompletions.forEach { $0() }
            if self.isRecording && result.submission == .eventPosted {
                self.commitAppleLiveSegmentIfNeeded(from: self.state.liveInsertion.latestText, isFinal: false)
            }
        }
    }
}
