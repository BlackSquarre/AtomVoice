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
    private let audioEngine: AudioEngineController
    private let presenter: RecordingSessionPresenting
    private let llmRefiner: LLMRefiner
    private let textOutputSinkRegistry: TextOutputSinkRegistry
    private let volumeController: VolumeController
    private let asrEngineProvider: ASREngineProviding
    private let recognitionFinalizer: RecognitionResultFinalizer
    private var recognitionSession: (any RecognitionSession)?
    weak var delegate: RecordingSessionDelegate?

    /// 录音中状态变化回调：true=进入录音，false=结束（用于同步外部组件如 FnKeyMonitor.isRecording）。
    /// (Recording-active state callback: true on enter, false on stop. Used to sync external components like FnKeyMonitor.isRecording.)
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onRefiningStateChanged: ((Bool) -> Void)?

    // MARK: - 状态（State）
    private var state = RecordingSessionState()
    private var streamSession: TextStreamSession?
    var isRecording: Bool { state.isRecording }
    var isRefining: Bool { state.isRefining }
    private var isStarting: Bool { state.isStarting }
    private(set) var currentRecordingEngine: String {
        get { state.currentRecordingEngine }
        set { state.currentRecordingEngine = newValue }
    }
    private var recordingGeneration: Int {
        get { state.recordingGeneration }
    }
    private var startRequestGeneration: Int {
        get { state.startRequestGeneration }
    }

    // MARK: - 协调器（Coordinators）
    private let audioAnalyzer = AudioAnalyzer()
    private let asrSilenceMonitor = ASRSilenceMonitor()
    /// AudioAnalyzer 订阅 router 16kHz 的消费者 ID；session 整体 deinit 时注销。
    /// (Analyzer's router consumer; unregistered on session deinit.)
    private var analyzerConsumerID: UUID?

    // MARK: - 计算属性（Computed）
    private var activeOutputSink: TextOutputSink { textOutputSinkRegistry.current() }
    private var streamingCompactKey: String? {
        streamSession != nil ? "capsule.streaming.typing" : nil
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
            self.onRefiningStateChanged?(refining)
            if refining {
                self.state.beginRefining(text: text)
            } else {
                _ = self.state.endRefining()
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

    private func beginCapsulePresentation(deferred: Bool) {
        state.deferredCapsule.begin(deferred: deferred)
    }

    private func resetDeferredCapsulePresentation() {
        state.resetDeferredCapsulePresentation()
    }

    private func activateTextOutputForRecordingIfNeeded() {
        guard state.beginTextOutputActivation() else { return }
        if activeOutputSink.descriptor.supportsStreaming {
            streamSession = activeOutputSink.beginStream()
        }
        state.liveInsertion.isActive = streamSession == nil &&
            (recognitionSession?.supportsLiveInsertion == true) &&
            AppSettings.appleLiveInsertionEnabled &&
            !AppSettings.llmEnabled
        clearLiveInsertionProgress()
    }

    private func revealDeferredRecordingPresentation() {
        guard state.deferredCapsule.isDeferred else { return }

        let presentation = state.deferredCapsule.pendingPresentation
        let shouldApplyShimmer = state.deferredCapsule.pendingShimmer
        let recognizedText = state.deferredCapsule.recognizedText
        let liveInsertionText = state.deferredCapsule.liveInsertionText
        let liveInsertionIsFinal = state.deferredCapsule.liveInsertionIsFinal

        state.resetDeferredCapsulePresentation()

        activateTextOutputForRecordingIfNeeded()

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
            updateRecognizedText(recognizedText)
        }
        if let liveInsertionText {
            commitAppleLiveSegmentIfNeeded(from: liveInsertionText, isFinal: liveInsertionIsFinal)
        }
    }

    private func showInitialCapsule() {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingPresentation = .initial
            return
        }
        presenter.present(.showInitial(compactStatusKey: streamingCompactKey))
    }

    private func showRecordingCapsule() {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingPresentation = .recording
            return
        }
        presenter.present(.showRecording)
    }

    private func showCapsuleProgress(_ text: String, hidesWaveform: Bool = true) {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingPresentation = .progress(text: text, hidesWaveform: hidesWaveform)
            return
        }
        presenter.present(.showProgress(text: text, hidesWaveform: hidesWaveform))
    }

    private func showCapsuleError(_ message: String, dismissAfter delay: TimeInterval, ensurePanel: Bool = false) {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingPresentation = .error(message: message, dismissAfter: delay)
            return
        }
        presenter.present(.showError(message: message, dismissAfter: delay, ensurePanel: ensurePanel))
    }

    private func updateCapsuleText(_ text: String) {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.recognizedText = text
            return
        }
        presenter.present(.updateText(text))
    }

    private func updateCapsuleBands(_ bands: [Float]) {
        guard !state.deferredCapsule.isDeferred else { return }
        presenter.present(.updateBands(bands))
    }

    private func applyCapsuleShimmer() {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingShimmer = true
            return
        }
        presenter.present(.startShimmer)
    }

    private func stopCapsuleShimmer() {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.pendingShimmer = false
            return
        }
        presenter.present(.stopShimmer)
    }

    // MARK: - 录音启动（Recording start）

    private func startRecording(deferCapsulePresentation: Bool = false) {
        guard let startRequest = state.beginStart(deferredCapsulePresentation: deferCapsulePresentation) else {
            return
        }

        // 输入设备/格式未就绪时（如 AirPods 热插拔造成的音频路由过渡），
        // 后台异步等待最多 500ms 再继续；主线程不阻塞。
        // (When input path isn't ready - e.g. AirPods hot-plug routing transition -
        //  wait asynchronously up to 500ms before continuing; main thread is never blocked.)
        // 始终走异步 preflight：仅检查设备列表非空不够，
        // AirPods 切换后 inputNode.outputFormat 可能仍是 0/0，需要强制刷新设备绑定。
        // (Always run async preflight: a non-empty device list isn't enough -
        //  inputNode.outputFormat may still be 0/0 after an AirPods route swap.)
        audioEngine.waitForInputReady(timeout: 0.5) { [weak self] ready in
            guard let self else { return }
            guard self.isStarting,
                  self.startRequestGeneration == startRequest,
                  !self.isRecording else { return }
            guard ready else {
                self.state.failStart()
                DebugLog.error("[Session] startRecording: preflight 失败，显示错误胶囊")
                self.showInitialCapsule()
                self.showCapsuleError(loc("error.noInputDevice"), dismissAfter: 5, ensurePanel: true)
                return
            }
            self.continueStartRecording(startRequest: startRequest)
        }
    }

    private func continueStartRecording(startRequest: Int) {
        guard state.acceptsStartRequest(startRequest) else { return }
        // Sherpa 引擎：直接按当前 preset 实读磁盘判断；isReady 内部含一次轻量自愈
        // (Sherpa engine: read disk for current preset; isReady includes one lightweight self-heal pass)
        let engine = AppSettings.normalizedRecognitionEngine
        let selectedSession = recognitionSession(for: engine)
        switch selectedSession.preflight() {
        case .ready:
            break
        case .requestExternalDownload(let redownload):
            state.failStart()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.sessionRequiresSherpaModelDownload(redownload: redownload)
            }
            return
        case .waitForExternalDownload:
            state.failStart()
            return
        case .failure(let error):
            state.failStart()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                showInitialCapsule()
                showCapsuleError(error, dismissAfter: 5, ensurePanel: true)
            }
            return
        }

        if state.isWaitingForDoubaoFinalResult {
            state.endDoubaoFinalWait()
            let pendingText = recognitionSession?.currentText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pendingText.isEmpty {
                activeOutputSink.deliver(text: pendingText, completion: nil)
            }
        }

        if isRefining {
            onRefiningStateChanged?(false)
            let pendingText = state.endRefining()
            if let pendingText, !pendingText.isEmpty {
                activeOutputSink.deliver(text: pendingText, completion: nil)
            }
        }

        // 取消正在进行的 LLM 处理，如果有（Cancel any ongoing LLM processing, if any）
        llmRefiner.cancel()
        recognitionSession?.cancel()
        recognitionSession = selectedSession

        onRecordingStateChanged?(true)
        asrSilenceMonitor.start()
        let generation = state.transitionToRecording(engine: AppSettings.normalizedRecognitionEngine)

        // 流式 sink：录音开始时一次性决定 AX/Paste 路径；启用后接管所有上屏，禁用 Apple live insertion
        // (Streaming sink: AX/Paste path decided once at record start; takes over on-screen output and disables Apple live insertion)
        streamSession?.cancel()
        streamSession = nil
        resetLiveInsertionState()
        if !state.deferredCapsule.isDeferred {
            activateTextOutputForRecordingIfNeeded()
        }

        let lowerVolume = AppSettings.lowerVolumeOnRecording
        DebugLog.info("[Session] startRecording: lowerVolume=\(lowerVolume)")
        if lowerVolume {
            volumeController.saveAndDecreaseVolume()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, isRecording, recordingGeneration == generation else { return }
            let callbacks = makeRecognitionSessionCallbacks(generation: generation)
            switch selectedSession.start(audioFormat: selectedSession.preferredAudioFormat, callbacks: callbacks) {
            case .started:
                break
            case .failed(let failure):
                handleRecognitionSessionStartFailure(failure)
            }
        }
    }

    private func makeRecognitionSessionCallbacks(generation: Int) -> RecognitionSessionCallbacks {
        RecognitionSessionCallbacks(
            isCurrent: { [weak self] in
                self?.recordingGeneration == generation
            },
            isRecordingCurrent: { [weak self] in
                guard let self else { return false }
                return self.isRecording && self.recordingGeneration == generation
            },
            copyAudioBuffer: { [weak self] buffer in
                self?.copyAudioBuffer(buffer)
            },
            onPartialResult: { [weak self] text, isFinal in
                guard let self else { return }
                self.updateRecognizedText(text)
                self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
            },
            onError: { [weak self] message in
                self?.showCapsuleError(message, dismissAfter: 5)
            },
            onShowInitial: { [weak self] in
                self?.showInitialCapsule()
            },
            onShowRecording: { [weak self] in
                self?.showRecordingCapsule()
            },
            onProgress: { [weak self] text, hidesWaveform in
                self?.showCapsuleProgress(text, hidesWaveform: hidesWaveform)
            },
            onDisplayText: { [weak self] text in
                self?.updateCapsuleText(text)
            },
            onShimmerChanged: { [weak self] active in
                active ? self?.applyCapsuleShimmer() : self?.stopCapsuleShimmer()
            },
            onEffectiveEngineChanged: { [weak self] code in
                self?.currentRecordingEngine = code
            },
            onStartFailure: { [weak self] failure in
                self?.handleRecognitionSessionStartFailure(failure)
            },
            onWaitingForFinalResultChanged: { [weak self] waiting in
                guard let self else { return }
                if waiting {
                    self.state.beginDoubaoFinalWait()
                } else {
                    self.state.endDoubaoFinalWait()
                }
            },
            onResetLiveInsertion: { [weak self] in
                self?.resetLiveInsertionState()
            }
        )
    }

    // MARK: - 启动失败处理（Start-failure handlers）

    private func handleAudioRouteRecoveryFailed() {
        guard isRecording else { return }
        DebugLog.error("[Session] 音频路由变化恢复失败，结束当前录音")
        markRecordingStopped()
        audioEngine.abandonAfterRouteRecoveryFailure()
        teardownInterruptedRecordingState(stopAudioEngine: false)
        showCapsuleError(loc("error.audioTapFailed"), dismissAfter: 5)
        delegate?.sessionDidEnd()
    }

    private func handleRecognitionSessionStartFailure(_ failure: RecognitionSessionFailure) {
        if failure.stopAudioEngine {
            audioEngine.stop()
        }
        markRecordingStopped()
        recognitionSession?.cancel()
        resetLiveInsertionState()
        showCapsuleError(failure.message, dismissAfter: failure.dismissAfter)
        switch failure.recovery {
        case .requestSherpaModelDownload(let redownload, let delay):
            SherpaModelDownloader.printMissingRequiredFiles()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.delegate?.sessionRequiresSherpaModelDownload(redownload: redownload)
            }
        case .none:
            break
        }
    }

    // MARK: - 实时识别更新与状态（Real-time updates & state）

    private func updateRecognizedText(_ text: String) {
        // 任何 partial / final 文本变化都喂给静音监控当心跳；只要 ASR 还在产文本就视为还在说话。
        asrSilenceMonitor.noteText(text)
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.recognizedText = text
            return
        }
        presenter.present(.updateText(text))
        streamSession?.update(currentText: text)
    }

    private func markRecordingStopped() {
        cancelPendingStart()
        state.markRecordingStopped()
        asrSilenceMonitor.stop()
        onRecordingStateChanged?(false)
        volumeController.restoreVolume()
        // 清掉 Apple Live Fallback 留下的 switchRequest 消费者（豆包回退路径用）
        audioEngine.clearSwitchedRequest()
        // 重置静音/FFT 滚动状态（下次录音从干净状态开始）
        audioAnalyzer.reset()
    }

    private func cancelPendingStart() {
        _ = state.cancelPendingStart()
    }

    private func clearLiveInsertionProgress() {
        state.liveInsertion.clearProgress()
    }

    private func resetLiveInsertionState() {
        state.liveInsertion.reset()
    }

    private func teardownInterruptedRecordingState(stopAudioEngine: Bool) {
        if isRefining {
            onRefiningStateChanged?(false)
        }

        state.clearInterruptedState()
        llmRefiner.cancel()

        recognitionSession?.cancel()
        if stopAudioEngine {
            audioEngine.stop()
        }
        resetLiveInsertionState()
        streamSession?.cancel()
        streamSession = nil
    }

    private func copyAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
        let generation = recordingGeneration
        markRecordingStopped()

        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.recognitionSession else { return }
            session.stop(
                immediate: false,
                appending: nil,
                callbacks: self.makeRecognitionSessionCallbacks(generation: generation)
            ) { [weak self] result in
                guard let self, self.recordingGeneration == generation else { return }
                self.finishRecognizedResult(
                    result.text,
                    errorMsg: result.errorMessage,
                    appending: result.appendingImmediatePunctuation
                )
            }
        }
    }

    private func cancelRecording() {
        guard isRecording || isRefining else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        
        state.invalidateGenerationForCancel()
        
        markRecordingStopped()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            teardownInterruptedRecordingState(stopAudioEngine: true)
            presenter.dismiss(completion: nil)
            delegate?.sessionDidEnd()
        }
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入。
    /// (Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly.)
    private func stopRecordingImmediate(appending punctuation: String? = nil) {
        guard isRecording else {
            cancelPendingStart()
            resetDeferredCapsulePresentation()
            return
        }
        let generation = recordingGeneration
        markRecordingStopped()

        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.recognitionSession else { return }
            session.stop(
                immediate: true,
                appending: punctuation,
                callbacks: self.makeRecognitionSessionCallbacks(generation: generation)
            ) { [weak self] result in
                guard let self, self.recordingGeneration == generation else { return }
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

    private func commitAppleLiveSegmentIfNeeded(from text: String, isFinal: Bool) {
        if state.deferredCapsule.isDeferred {
            state.deferredCapsule.liveInsertionText = text
            state.deferredCapsule.liveInsertionIsFinal = state.deferredCapsule.liveInsertionIsFinal || isFinal
            return
        }
        guard state.liveInsertion.isActive,
              isRecording,
              recognitionSession?.supportsLiveInsertion == true
        else { return }
        state.liveInsertion.latestText = text
        guard !state.liveInsertion.pasteInFlight else { return }
        guard text.hasPrefix(state.liveInsertion.committedText) else { return }

        let uncommitted = String(text.dropFirst(state.liveInsertion.committedText.count))
        guard let endIndex = committableLiveSegmentEnd(in: uncommitted, isFinal: isFinal) else { return }

        let segment = String(uncommitted[..<endIndex])
        guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        state.liveInsertion.committedText += segment
        state.liveInsertion.pasteInFlight = true
        activeOutputSink.deliver(text: segment) { [weak self] in
            guard let self else { return }
            self.state.liveInsertion.pasteInFlight = false
            if self.isRecording {
                self.commitAppleLiveSegmentIfNeeded(from: self.state.liveInsertion.latestText, isFinal: false)
            }
        }
    }

    private func committableLiveSegmentEnd(in text: String, isFinal: Bool) -> String.Index? {
        var sentenceEnds: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if PunctuationProcessor.isSentenceEndingPunctuation(text[index]) {
                var end = next
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                sentenceEnds.append(end)
            }
            index = next
        }

        for end in sentenceEnds.reversed() {
            let candidate = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 3, isFinal || trailing.count >= 3 {
                return end
            }
        }

        return nil
    }
}
