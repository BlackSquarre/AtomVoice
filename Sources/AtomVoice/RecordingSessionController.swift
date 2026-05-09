import Cocoa
import AVFoundation

/// 录音会话委托：Session 通过它访问 AppDelegate 持有的引擎工厂与 Sherpa 模型流程。
/// (Recording session delegate: Session uses it to access engine factories and Sherpa flows owned by AppDelegate.)
protocol RecordingSessionDelegate: AnyObject {
    func sessionRequiresAppleASREngine() -> AppleSpeechASREngine
    func sessionRequiresSherpaASREngine() -> SherpaOnnxASREngine
    func sessionRequiresVolcengineASREngine() -> VolcengineASREngine
    func sessionRequiresSpeechRecognizer() -> SpeechRecognizerController
    func sessionRequiresSherpaModelDownload(redownload: Bool)
    func sessionDidEnd()
}

/// 录音状态机：从 Fn 按下到识别结果上屏的全部流水线。
/// (Recording state machine: full pipeline from Fn press through recognition delivery.)
final class RecordingSessionController {
    // MARK: - 依赖（Dependencies）
    private let audioEngine: AudioEngineController
    private let capsuleWindow: CapsuleWindowController
    private let llmRefiner: LLMRefiner
    private let textPostProcessorRegistry: TextPostProcessorRegistry
    private let textOutputSinkRegistry: TextOutputSinkRegistry
    private let volumeController: VolumeController
    private let asrEngineRegistry: ASREngineRegistry
    weak var delegate: RecordingSessionDelegate?

    /// 录音中状态变化回调：true=进入录音，false=结束（用于同步外部组件如 FnKeyMonitor.isRecording）。
    /// (Recording-active state callback: true on enter, false on stop. Used to sync external components like FnKeyMonitor.isRecording.)
    var onRecordingStateChanged: ((Bool) -> Void)?

    // MARK: - 状态（State）
    private(set) var isRecording = false
    private(set) var currentRecordingEngine = ASREngineRegistry.appleCode
    private var recordingGeneration = 0
    private var liveInsertionActive = false
    private var liveInsertionCommittedText = ""
    private var liveInsertionLatestText = ""
    private var liveInsertionPasteInFlight = false
    private var streamSession: TextStreamSession?

    // MARK: - 协调器（Coordinators）
    let sherpaPreload = SherpaPreloadCoordinator()
    let doubaoFallback = DoubaoFallbackCoordinator()
    private lazy var appleLiveFallback: AppleLiveFallbackStrategy = AppleLiveFallbackStrategy(
        audioEngine: audioEngine,
        fallback: doubaoFallback,
        speechRecognizerProvider: { [unowned self] in
            self.delegate!.sessionRequiresSpeechRecognizer()
        }
    )

    // MARK: - 计算属性（Computed）
    private var activeOutputSink: TextOutputSink { textOutputSinkRegistry.current() }
    private var streamingCompactKey: String? {
        streamSession != nil ? "capsule.streaming.typing" : nil
    }
    private func appleEngine() -> AppleSpeechASREngine { delegate!.sessionRequiresAppleASREngine() }
    private func sherpaEngine() -> SherpaOnnxASREngine { delegate!.sessionRequiresSherpaASREngine() }
    private func volcengineEngine() -> VolcengineASREngine { delegate!.sessionRequiresVolcengineASREngine() }
    private func speechRecognizer() -> SpeechRecognizerController { delegate!.sessionRequiresSpeechRecognizer() }
    private func asrEngine(for code: String) -> ASREngine {
        switch code {
        case VolcengineASRSettings.engineCode:
            return volcengineEngine()
        case ASREngineRegistry.sherpaCode:
            return sherpaEngine()
        default:
            return appleEngine()
        }
    }

    init(
        audioEngine: AudioEngineController,
        capsuleWindow: CapsuleWindowController,
        llmRefiner: LLMRefiner,
        textPostProcessorRegistry: TextPostProcessorRegistry,
        textOutputSinkRegistry: TextOutputSinkRegistry,
        volumeController: VolumeController,
        asrEngineRegistry: ASREngineRegistry
    ) {
        self.audioEngine = audioEngine
        self.capsuleWindow = capsuleWindow
        self.llmRefiner = llmRefiner
        self.textPostProcessorRegistry = textPostProcessorRegistry
        self.textOutputSinkRegistry = textOutputSinkRegistry
        self.volumeController = volumeController
        self.asrEngineRegistry = asrEngineRegistry
    }

    // MARK: - 公开 API（Public API）

    func start() { startRecording() }
    func stop() { stopRecording() }
    func stopImmediate(appending punctuation: String?) { stopRecordingImmediate(appending: punctuation) }
    func cancel() { cancelRecording() }

    // MARK: - 录音启动（Recording start）

    private func startRecording() {
        guard !isRecording else { return }

        guard !AudioEngineController.availableInputDevices().isEmpty else {
            DispatchQueue.main.async { [self] in
                capsuleWindow.show()
                capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
            }
            return
        }

        // Sherpa 引擎：直接按当前 preset 实读磁盘判断；isReady 内部含一次轻量自愈
        // (Sherpa engine: read disk for current preset; isReady includes one lightweight self-heal pass)
        let engine = AppSettings.normalizedRecognitionEngine
        let selectedASREngine = asrEngine(for: engine)
        if asrEngineRegistry.isSherpa(engine) {
            if !SherpaModelDownloader.isReady() {
                if SherpaModelDownloader.shared.isDownloading { return }
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.sessionRequiresSherpaModelDownload(redownload: false)
                }
                return
            }
        }
        if engine == VolcengineASRSettings.engineCode {
            guard AppSettings.doubaoASRPrivacyAccepted else {
                DispatchQueue.main.async { [self] in
                    capsuleWindow.show()
                    capsuleWindow.showError(loc("doubao.error.privacyNotAccepted"), dismissAfter: 5)
                }
                return
            }
            if let error = selectedASREngine.validate() {
                DispatchQueue.main.async { [self] in
                    capsuleWindow.show()
                    capsuleWindow.showError(error, dismissAfter: 5)
                }
                return
            }
        }

        // 取消正在进行的 LLM 处理，如果有（Cancel any ongoing LLM processing, if any）
        llmRefiner.cancel()
        doubaoFallback.reset()

        isRecording = true
        onRecordingStateChanged?(true)
        recordingGeneration += 1
        let generation = recordingGeneration
        currentRecordingEngine = AppSettings.normalizedRecognitionEngine

        // 流式 sink：录音开始时一次性决定 AX/Paste 路径；启用后接管所有上屏，禁用 Apple live insertion
        // (Streaming sink: AX/Paste path decided once at record start; takes over on-screen output and disables Apple live insertion)
        streamSession?.cancel()
        streamSession = nil
        if activeOutputSink.descriptor.supportsStreaming {
            streamSession = activeOutputSink.beginStream()
        }

        liveInsertionActive = streamSession == nil &&
            asrEngineRegistry.isApple(currentRecordingEngine) &&
            AppSettings.appleLiveInsertionEnabled &&
            !AppSettings.llmEnabled
        clearLiveInsertionProgress()

        let lowerVolume = AppSettings.lowerVolumeOnRecording
        DebugLog.info("[Session] startRecording: lowerVolume=\(lowerVolume)")
        if lowerVolume {
            volumeController.saveAndDecreaseVolume()
        }

        DispatchQueue.main.async { [self] in
            guard isRecording, recordingGeneration == generation else { return }

            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                startDoubaoRecording(generation: generation)
            } else if asrEngineRegistry.isSherpa(currentRecordingEngine) {
                capsuleWindow.show(compactStatusKey: streamingCompactKey)
                if sherpaEngine().isModelLoaded {
                    // 模型已缓存，直接开始录音，不显示加载动画（Model cached, start recording directly without loading animation）
                    startSherpaRecordingAfterModelLoad(generation: generation)
                } else {
                    // 首次加载模型：立即录音 + 后台加载模型 + 加载完成后喂缓存音频（First-time: record immediately + load model in background + feed buffered audio after load）
                    startSherpaRecordingWithDeferredModel(generation: generation)
                }
            } else {
                startAppleRecording(generation: generation)
            }
        }
    }

    private func startAppleRecording(generation: Int) {
        guard isRecording, recordingGeneration == generation else { return }

        capsuleWindow.show(compactStatusKey: streamingCompactKey)
        if let error = appleEngine().start(
            onResult: { [weak self] text, isFinal in
                DispatchQueue.main.async {
                    guard let self,
                          self.recordingGeneration == generation,
                          self.isRecording,
                          self.asrEngineRegistry.isApple(self.currentRecordingEngine)
                    else { return }
                    self.updateRecognizedText(text)
                    self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.capsuleWindow.showError(error, dismissAfter: 5)
                }
            }
        ) {
            handleRecognitionStartFailure(error)
            return
        }

        if !audioEngine.start(
            bandsHandler: makeBandsHandler(),
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                guard let self,
                      self.recordingGeneration == generation,
                      self.isRecording,
                      self.asrEngineRegistry.isApple(self.currentRecordingEngine)
                else { return }
                self.appleEngine().accept(buffer: buffer)
            }
        ) {
            appleEngine().cancel()
            handleAudioStartFailure()
        }
    }

    private func startSherpaRecordingAfterModelLoad(generation: Int) {
        if let error = sherpaEngine().start(onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self,
                      self.recordingGeneration == generation,
                      self.isRecording,
                      self.asrEngineRegistry.isSherpa(self.currentRecordingEngine)
                else { return }
                self.updateRecognizedText(text)
            }
        }, onError: { _ in }) {
            handleSherpaStartFailure(error)
            return
        }

        capsuleWindow.showRecording()
        if !audioEngine.start(
            bandsHandler: makeBandsHandler(),
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                guard let self,
                      self.recordingGeneration == generation,
                      self.isRecording,
                      self.asrEngineRegistry.isSherpa(self.currentRecordingEngine)
                else { return }
                self.sherpaEngine().accept(buffer: buffer)
            }
        ) {
            sherpaEngine().cancel()
            handleAudioStartFailure()
        }
    }

    /// Sherpa 模型未加载时：立即启动录音缓存音频，后台加载模型，加载完成后喂入全部缓存并无缝切换。
    /// (Sherpa model not loaded: start audio immediately and buffer, load model in background, drain buffer when ready.)
    private func startSherpaRecordingWithDeferredModel(generation: Int) {
        sherpaPreload.begin()

        capsuleWindow.showProgress(loc("sherpa.loadingModel"))

        // 1. 立即启动 AudioEngine，缓存音频（Start AudioEngine immediately, buffer audio）
        if !audioEngine.start(
            bandsHandler: makeBandsHandler(),
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                guard let self,
                      self.recordingGeneration == generation,
                      self.isRecording,
                      self.asrEngineRegistry.isSherpa(self.currentRecordingEngine)
                else { return }
                let buffered = self.sherpaPreload.appendIfActive(buffer) { self.copyAudioBuffer($0) }
                if !buffered {
                    self.sherpaEngine().accept(buffer: buffer)
                }
            }
        ) {
            sherpaPreload.cancel()
            handleAudioStartFailure()
            return
        }

        // 2. 后台加载模型（Load model in background）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.sherpaEngine().start(onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    guard let self,
                          self.recordingGeneration == generation,
                          self.isRecording,
                          self.asrEngineRegistry.isSherpa(self.currentRecordingEngine)
                    else { return }
                    self.updateRecognizedText(text)
                }
            }, onError: { _ in })

            // 3. 回主线程处理结果（Return to main thread to handle result）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isRecording, self.recordingGeneration == generation,
                      self.asrEngineRegistry.isSherpa(self.currentRecordingEngine) else {
                    self.sherpaPreload.cancel()
                    return
                }

                if let error {
                    // 模型加载失败，停止录音（Model load failed, stop recording）
                    self.sherpaPreload.cancel()
                    self.handleSherpaStartFailure(error, stopAudioEngine: true)
                    return
                }

                // 4. 模型加载成功，排空缓存后切换到直推模式（Model loaded, drain buffer then switch to live mode）
                self.sherpaPreload.drain(
                    accept: { [weak self] buf in
                        self?.sherpaEngine().accept(buffer: buf)
                    },
                    onComplete: { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.isRecording, self.recordingGeneration == generation else { return }
                            self.capsuleWindow.stopShimmer()
                            self.capsuleWindow.showRecording()
                        }
                    }
                )
            }
        }
    }

    private func startDoubaoRecording(generation: Int) {
        guard isRecording, recordingGeneration == generation else { return }
        DebugLog.info("[Session] 启动豆包录音, generation=\(generation)")
        doubaoFallback.beginWaitingForFirstResult()
        capsuleWindow.show(compactStatusKey: streamingCompactKey)
        capsuleWindow.showRecording()
        // 延迟一帧挂扫光，表示正在连接（Delay one frame to apply shimmer, indicating connecting）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingGeneration == generation, self.isRecording else { return }
            self.capsuleWindow.applyShimmerToCapsule()
        }
        if let error = volcengineEngine().start(onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                if self.doubaoFallback.acceptCloudText(text) {
                    // 收到第一条结果，停掉连接扫光并丢弃 fallback 缓冲（Stop connecting shimmer and discard fallback buffers on first result）
                    self.capsuleWindow.stopShimmer()
                }
                self.updateRecognizedText(text)
            }
        }, onError: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.handleDoubaoRecognitionError(message)
            }
        }) {
            doubaoFallback.reset()
            currentRecordingEngine = ASREngineRegistry.appleCode
            DebugLog.error("[Doubao] 启动失败，回退到 Apple Speech: \(error)")
            startAppleRecording(generation: generation)
            capsuleWindow.updateText(loc("menu.recognitionEngine.apple"))
            return
        }

        if !audioEngine.start(
            bandsHandler: makeBandsHandler(),
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                guard let self else { return }
                self.doubaoFallback.appendAudioBufferIfWaiting(buffer, copyBuffer: self.copyAudioBuffer)
                self.volcengineEngine().accept(buffer: buffer)
            }
        ) {
            volcengineEngine().cancel()
            handleAudioStartFailure()
        }
    }

    private func handleDoubaoRecognitionError(_ message: String) {
        guard currentRecordingEngine == VolcengineASRSettings.engineCode else { return }
        let isBenignSilenceError = appleLiveFallback.isBenignSilenceError(
            message,
            cloudCurrentText: volcengineEngine().currentText
        )
        let visibleError = isBenignSilenceError ? "" : message
        guard doubaoFallback.recordError(visibleError, currentText: volcengineEngine().currentText) else { return }

        DebugLog.error("[Session] 豆包识别错误: \(message), isRecording=\(isRecording)")

        volcengineEngine().cancel()
        resetLiveInsertionState()

        if isRecording {
            startAppleLiveFallbackAfterDoubaoError(generation: recordingGeneration)
            DebugLog.error("[Doubao] 识别失败，录音结束后将回退到 Apple Speech: \(message)")
        } else if !isBenignSilenceError {
            capsuleWindow.showError(loc("doubao.fallback.withError", message), dismissAfter: 5)
        }
    }

    private func startAppleLiveFallbackAfterDoubaoError(generation: Int) {
        guard isRecording,
              recordingGeneration == generation,
              currentRecordingEngine == VolcengineASRSettings.engineCode
        else { return }

        let initialText = appleLiveFallback.engage(onPartial: { [weak self] merged in
            guard let self, self.recordingGeneration == generation else { return }
            self.updateRecognizedText(merged)
        })
        guard let initialText else { return }   // 已经激活 (already engaged)

        DebugLog.info("[Session] 启动 Apple 实时回退 (豆包错误后)")
        capsuleWindow.stopShimmer()
        capsuleWindow.updateText(initialText)
    }

    // MARK: - 启动失败处理（Start-failure handlers）

    private func handleAudioStartFailure() {
        markRecordingStopped()
        doubaoFallback.reset()
        resetLiveInsertionState()
        capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
    }

    private func handleRecognitionStartFailure(_ message: String) {
        markRecordingStopped()
        resetLiveInsertionState()
        capsuleWindow.showError(message, dismissAfter: 5)
    }

    private func handleSherpaStartFailure(_ error: String, stopAudioEngine: Bool = false) {
        if stopAudioEngine {
            audioEngine.stop()
        }
        markRecordingStopped()
        DebugLog.error("[SherpaOnnx] 模型加载失败: \(error)")

        let failureKind = sherpaEngine().lastStartFailureKind
        let needsRedownload =
            failureKind == .missingRuntime ||
            failureKind == .missingModel ||
            failureKind == .invalidModel

        if needsRedownload {
            SherpaModelDownloader.printMissingRequiredFiles()
            capsuleWindow.showError(error, dismissAfter: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.delegate?.sessionRequiresSherpaModelDownload(redownload: true)
            }
        } else {
            // 文件存在但加载失败（dylib 问题等），只报错（Files exist but load failed (e.g. dylib issue), only show error）
            capsuleWindow.showError(error, dismissAfter: 6)
        }
    }

    // MARK: - 实时识别更新与状态（Real-time updates & state）

    private func updateRecognizedText(_ text: String) {
        capsuleWindow.updateText(text)
        streamSession?.update(currentText: text)
    }

    private func markRecordingStopped() {
        isRecording = false
        onRecordingStateChanged?(false)
        volumeController.restoreVolume()
    }

    private func makeBandsHandler() -> ([Float]) -> Void {
        { [weak self] bands in
            DispatchQueue.main.async {
                self?.capsuleWindow.updateBands(bands)
            }
        }
    }

    private func stopCurrentLocalASREngineSynchronously() -> String {
        if asrEngineRegistry.isSherpa(currentRecordingEngine) {
            return sherpaEngine().stopSynchronously()
        }
        return appleEngine().stopSynchronously()
    }

    private func cancelCurrentRecognition(shouldStopAppleLiveFallback: Bool = false) {
        if currentRecordingEngine == VolcengineASRSettings.engineCode {
            volcengineEngine().cancel()
            if shouldStopAppleLiveFallback {
                _ = speechRecognizer().stop()
            }
        } else if asrEngineRegistry.isSherpa(currentRecordingEngine) {
            sherpaEngine().cancel()
        } else {
            appleEngine().cancel()
        }
    }

    private func clearLiveInsertionProgress() {
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false
    }

    private func resetLiveInsertionState() {
        liveInsertionActive = false
        clearLiveInsertionProgress()
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

    /// Doubao 收尾路径：若 fallback 已激活或已记录错误，取消云端连接并走 Apple fallback 完成。
    /// (Doubao end-of-recording: if fallback active or has recorded error, cancel cloud and finish via Apple fallback.)
    private func consumeDoubaoFallbackIfNeeded(
        generation: Int,
        appendingImmediatePunctuation punctuation: String? = nil
    ) -> Bool {
        guard doubaoFallback.currentError != nil || doubaoFallback.isAppleLiveActive else {
            return false
        }
        volcengineEngine().cancel()
        finishDoubaoRecordingWithAppleFallback(
            generation: generation,
            originalError: doubaoFallback.currentError ?? "",
            appendingImmediatePunctuation: punctuation
        )
        return true
    }

    // MARK: - 录音收尾（Recording stop / cancel / immediate）

    private func stopRecording() {
        guard isRecording else { return }
        let generation = recordingGeneration
        markRecordingStopped()

        DispatchQueue.main.async { [self] in
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                audioEngine.stop()
                if consumeDoubaoFallbackIfNeeded(generation: generation) { return }
                volcengineEngine().stop { [weak self] recognizedText, errorMsg in
                    guard let self, self.recordingGeneration == generation else { return }
                    if let errorMsg {
                        self.finishDoubaoRecordingWithAppleFallback(
                            generation: generation,
                            originalError: errorMsg,
                            fallbackTextIfAppleEmpty: recognizedText
                        )
                    } else {
                        self.doubaoFallback.finishSuccessfulCloudRecognition()
                        self.finishRecording(with: recognizedText)
                    }
                }
                return
            }

            let recognizedText = stopCurrentLocalASREngineSynchronously()
            audioEngine.stop()
            finishRecording(with: recognizedText)
        }
    }

    private func cancelRecording() {
        markRecordingStopped()

        DispatchQueue.main.async { [self] in
            llmRefiner.cancel()
            let shouldStopAppleLiveFallback = doubaoFallback.cancel()
            cancelCurrentRecognition(shouldStopAppleLiveFallback: shouldStopAppleLiveFallback)
            audioEngine.stop()
            sherpaPreload.cancel()
            resetLiveInsertionState()
            streamSession?.cancel()
            streamSession = nil
            capsuleWindow.dismiss()
            delegate?.sessionDidEnd()
        }
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入。
    /// (Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly.)
    private func stopRecordingImmediate(appending punctuation: String? = nil) {
        guard isRecording else { return }
        let generation = recordingGeneration
        markRecordingStopped()

        DispatchQueue.main.async { [self] in
            let recognizedText: String
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                audioEngine.stop()
                if consumeDoubaoFallbackIfNeeded(generation: generation, appendingImmediatePunctuation: punctuation) {
                    return
                }
                recognizedText = volcengineEngine().currentText
                volcengineEngine().cancel()
            } else {
                recognizedText = stopCurrentLocalASREngineSynchronously()
                audioEngine.stop()
            }
            doubaoFallback.reset()
            finishImmediateRecording(with: recognizedText, appending: punctuation)
        }
    }

    private func finishDoubaoRecordingWithAppleFallback(
        generation: Int,
        originalError: String,
        fallbackTextIfAppleEmpty: String = "",
        appendingImmediatePunctuation punctuation: String? = nil
    ) {
        let fallback = doubaoFallback.makeFallbackSnapshot(
            originalError: originalError,
            fallbackTextIfAppleEmpty: fallbackTextIfAppleEmpty,
            stopLiveFallback: { [weak self] in self?.speechRecognizer().stop() ?? "" }
        )
        let fallbackError = fallback.originalError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fallback.originalError

        guard !fallback.buffers.isEmpty else {
            currentRecordingEngine = ASREngineRegistry.appleCode
            let text = DoubaoFallbackCoordinator.combinedText(
                prefix: fallback.cloudPrefixText,
                cachedText: "",
                liveText: fallback.liveFallbackText
            )
            finishRecognizedResult(text, errorMsg: text.isEmpty ? fallbackError : nil, appending: punctuation)
            return
        }

        currentRecordingEngine = ASREngineRegistry.appleCode
        capsuleWindow.showProgress(loc("menu.recognitionEngine.apple"))
        speechRecognizer().recognize(buffers: fallback.buffers, onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                let merged = DoubaoFallbackCoordinator.combinedText(
                    prefix: fallback.cloudPrefixText,
                    cachedText: text,
                    liveText: fallback.liveFallbackText
                )
                self.updateRecognizedText(merged)
            }
        }) { [weak self] appleText in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                let recognizedText = DoubaoFallbackCoordinator.combinedText(
                    prefix: fallback.cloudPrefixText,
                    cachedText: appleText,
                    liveText: fallback.liveFallbackText
                )
                let errorMsg = recognizedText.isEmpty ? fallbackError : nil

                self.finishRecognizedResult(recognizedText, errorMsg: errorMsg, appending: punctuation)
            }
        }
    }

    private func finishRecording(with recognizedText: String, errorMsg: String? = nil) {
        defer { delegate?.sessionDidEnd() }
        let rawText = remainingTextAfterLiveInsertion(recognizedText)

        // 流式 sink 路径：ASR 文字已上屏；按需做 LLM 替换或自动标点替换，然后关闭会话
        // (Streaming sink path: ASR text already on screen; do LLM/punctuation replacement as needed, then close the session)
        if let session = streamSession {
            finishStreamingRecording(session: session, rawText: rawText, errorMsg: errorMsg)
            return
        }

        if rawText.isEmpty {
            showRecordingResultErrorOrDismiss(errorMsg)
            return
        }

        let processedText = processedTextForFinalResult(rawText)
        if shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: true) {
            capsuleWindow.showRefining()
            llmRefiner.refine(text: processedText, onProgress: { [weak self] partial in
                self?.capsuleWindow.updateText(partial)
            }) { [weak self] refined, errorMsg in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let errorMsg {
                        // 立即注入文字，同时胶囊显示错误 3 秒（Inject text immediately, while capsule shows error for 3 seconds）
                        self.activeOutputSink.deliver(text: processedText, completion: nil)
                        self.capsuleWindow.showError(errorMsg)
                        return
                    }
                    let finalText = refined ?? processedText
                    self.capsuleWindow.updateText(finalText)
                    let delay = AppSettings.llmResultDelay
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.capsuleWindow.dismiss {
                            self.activeOutputSink.deliver(text: finalText, completion: nil)
                        }
                    }
                }
            }
        } else {
            dismissAndDeliver(processedText)
        }
    }

    /// 流式 sink 模式下的录音结束流程：替换/补标点/调 LLM，然后关闭 session。
    /// (Recording-finish flow under streaming sink: replace / add punctuation / run LLM, then close the session.)
    private func finishStreamingRecording(session: TextStreamSession, rawText: String, errorMsg: String?) {
        if rawText.isEmpty {
            cancelStreamingResult(session, errorMsg: errorMsg)
            return
        }

        let processedText = processedTextForFinalResult(rawText)
        if shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: false) {
            capsuleWindow.showRefining()
            llmRefiner.refine(text: processedText, onProgress: { [weak self] partial in
                self?.capsuleWindow.updateText(partial)
            }) { [weak self] refined, llmError in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let finalText = refined ?? processedText
                    let toApply = llmError != nil ? processedText : finalText
                    self.finalizeStreamSession(session, replacingWith: toApply)
                    if let llmError {
                        self.capsuleWindow.showError(llmError)
                    } else {
                        self.capsuleWindow.updateText(finalText)
                        let delay = AppSettings.llmResultDelay
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.capsuleWindow.dismiss()
                        }
                    }
                }
            }
        } else {
            // 无 LLM：仅在自动标点改了文本时做替换；否则原样提交即可
            // (No LLM: only replace when auto-punctuation changed the text; otherwise commit as-is)
            let replacement: String? = (processedText != rawText) ? processedText : nil
            capsuleWindow.dismiss { [weak self] in
                self?.finalizeStreamSession(session, replacingWith: replacement)
            }
        }
    }

    private func finishImmediateRecording(with recognizedText: String, appending punctuation: String?, errorMsg: String? = nil) {
        defer { delegate?.sessionDidEnd() }
        let rawText = remainingTextAfterLiveInsertion(recognizedText)

        // 流式 sink 路径：文本已上屏；标点直接追加在末尾即可
        // (Streaming sink path: text already on screen; punctuation just appended at the end)
        if let session = streamSession {
            if rawText.isEmpty {
                cancelStreamingImmediateResult(session, errorMsg: errorMsg, punctuation: punctuation)
                return
            }
            let processedText = processedTextForFinalResult(rawText, isImmediateFinish: true)
            let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)
            capsuleWindow.dismiss { [weak self] in
                self?.finalizeStreamSession(session, replacingWith: finalText != rawText ? finalText : nil)
            }
            return
        }

        if rawText.isEmpty {
            if let errorMsg, punctuation?.isEmpty ?? true {
                capsuleWindow.showError(errorMsg, dismissAfter: 5)
                return
            }

            dismissAndDeliverPunctuationOnly(punctuation)
            return
        }

        // 本地自动标点（保留），但跳过 LLM（Local auto-punctuation applied, but skip LLM）
        let processedText = processedTextForFinalResult(rawText, isImmediateFinish: true)
        let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)

        dismissAndDeliver(finalText)
    }

    private func finishRecognizedResult(_ text: String, errorMsg: String? = nil, appending punctuation: String? = nil) {
        if punctuation != nil {
            finishImmediateRecording(with: text, appending: punctuation, errorMsg: errorMsg)
        } else {
            finishRecording(with: text, errorMsg: errorMsg)
        }
    }

    // MARK: - Apple live insertion 段落提交（Apple live segment commit）

    private func commitAppleLiveSegmentIfNeeded(from text: String, isFinal: Bool) {
        guard liveInsertionActive, isRecording, asrEngineRegistry.isApple(currentRecordingEngine) else { return }
        liveInsertionLatestText = text
        guard !liveInsertionPasteInFlight else { return }
        guard text.hasPrefix(liveInsertionCommittedText) else { return }

        let uncommitted = String(text.dropFirst(liveInsertionCommittedText.count))
        guard let endIndex = committableLiveSegmentEnd(in: uncommitted, isFinal: isFinal) else { return }

        let segment = String(uncommitted[..<endIndex])
        guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        liveInsertionCommittedText += segment
        liveInsertionPasteInFlight = true
        activeOutputSink.deliver(text: segment) { [weak self] in
            guard let self else { return }
            self.liveInsertionPasteInFlight = false
            if self.isRecording {
                self.commitAppleLiveSegmentIfNeeded(from: self.liveInsertionLatestText, isFinal: false)
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

    private func remainingTextAfterLiveInsertion(_ text: String) -> String {
        guard liveInsertionActive, !liveInsertionCommittedText.isEmpty else { return text }

        if text.hasPrefix(liveInsertionCommittedText) {
            return String(text.dropFirst(liveInsertionCommittedText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let committed = liveInsertionCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty, text.hasPrefix(committed) {
            return String(text.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commonPrefixEnd = commonPrefixEndIndex(in: text, with: liveInsertionCommittedText)
        let commonPrefixLength = text.distance(from: text.startIndex, to: commonPrefixEnd)
        if commonPrefixLength > 0 {
            DebugLog.info("[LiveInsertion] 最终文本与已上屏前缀不完全一致，从共同前缀后继续注入")
            return String(text[commonPrefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        DebugLog.info("[LiveInsertion] 最终文本与已上屏前缀不一致，注入完整最终文本以避免丢字")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commonPrefixEndIndex(in text: String, with prefix: String) -> String.Index {
        var textIndex = text.startIndex
        var prefixIndex = prefix.startIndex

        while textIndex < text.endIndex,
              prefixIndex < prefix.endIndex,
              text[textIndex] == prefix[prefixIndex] {
            textIndex = text.index(after: textIndex)
            prefixIndex = prefix.index(after: prefixIndex)
        }

        return textIndex
    }

    // MARK: - 文本后处理（Text post-processing）

    private func applyAutoPunctuation(to rawText: String, isImmediateFinish: Bool = false) -> String {
        let lang = AppSettings.selectedLanguage
        let context = TextProcessingContext(
            engineCode: currentRecordingEngine,
            language: lang,
            isImmediateFinish: isImmediateFinish
        )
        return textPostProcessorRegistry.run(rawText, context: context)
    }

    private func removingTrailingSentencePunctuation(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            result.removeLast()
        }
        return result
    }

    private func processedTextForFinalResult(_ rawText: String, isImmediateFinish: Bool = false) -> String {
        let processedText = applyAutoPunctuation(to: rawText, isImmediateFinish: isImmediateFinish)
        if processedText != rawText {
            capsuleWindow.updateText(processedText)
        }
        return processedText
    }

    private func textByAppendingImmediatePunctuation(_ punctuation: String?, to text: String) -> String {
        guard let punctuation, !punctuation.isEmpty else { return text }
        return removingTrailingSentencePunctuation(from: text) + punctuation
    }

    private func shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: Bool) -> Bool {
        guard AppSettings.llmEnabled, !AppSettings.llmAPIKey.isEmpty else { return false }
        return !(skipWhenLiveInsertionCommitted && !liveInsertionCommittedText.isEmpty)
    }

    // MARK: - 收尾辅助（Finish helpers）

    private func showRecordingResultErrorOrDismiss(_ errorMsg: String?) {
        if let errorMsg {
            capsuleWindow.showError(errorMsg, dismissAfter: 5)
        } else {
            capsuleWindow.dismiss()
        }
    }

    private func cancelStreamingResult(_ session: TextStreamSession, errorMsg: String?) {
        session.cancel()
        streamSession = nil
        showRecordingResultErrorOrDismiss(errorMsg)
    }

    private func cancelStreamingImmediateResult(_ session: TextStreamSession, errorMsg: String?, punctuation: String?) {
        session.cancel()
        streamSession = nil
        if let errorMsg, punctuation?.isEmpty ?? true {
            capsuleWindow.showError(errorMsg, dismissAfter: 5)
            return
        }
        dismissAndDeliverPunctuationOnly(punctuation)
    }

    private func finalizeStreamSession(_ session: TextStreamSession, replacingWith replacement: String?) {
        session.finalize(replacingWith: replacement) { [weak self] in
            self?.streamSession = nil
        }
    }

    private func dismissAndDeliver(_ text: String) {
        capsuleWindow.dismiss { [self] in
            activeOutputSink.deliver(text: text, completion: nil)
        }
    }

    private func dismissAndDeliverPunctuationOnly(_ punctuation: String?) {
        capsuleWindow.dismiss { [self] in
            if let punctuation, !punctuation.isEmpty {
                activeOutputSink.deliver(text: punctuation, completion: nil)
            }
        }
    }
}
