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
    private let capsuleWindow: CapsuleWindowController
    private let llmRefiner: LLMRefiner
    private let textOutputSinkRegistry: TextOutputSinkRegistry
    private let volumeController: VolumeController
    private let asrEngineRegistry: ASREngineRegistry
    private let asrEngineProvider: ASREngineProviding
    private let recognitionFinalizer: RecognitionResultFinalizer
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

    /// 当前录音在 AudioRouter 上注册的消费者 ID（Sherpa/豆包/Apple 各家会注册自己想要的目标 format）。
    /// 任一时刻只有一个引擎在录音，所以单字段足够。markRecordingStopped 时注销。
    /// (Single consumer id per active recording session; cleared in markRecordingStopped.)
    private var activeRouterConsumerID: UUID?

    // MARK: - 协调器（Coordinators）
    let sherpaPreload = SherpaPreloadCoordinator()
    let doubaoFallback = DoubaoFallbackCoordinator()
    private let audioAnalyzer = AudioAnalyzer()
    /// AudioAnalyzer 订阅 router 16kHz 的消费者 ID；session 整体 deinit 时注销。
    /// (Analyzer's router consumer; unregistered on session deinit.)
    private var analyzerConsumerID: UUID?
    private lazy var appleLiveFallback: AppleLiveFallbackStrategy = AppleLiveFallbackStrategy(
        audioEngine: audioEngine,
        fallback: doubaoFallback,
        speechRecognizerProvider: { [unowned self] in
            self.asrEngineProvider.speechRecognizer()
        }
    )

    // MARK: - 计算属性（Computed）
    private var activeOutputSink: TextOutputSink { textOutputSinkRegistry.current() }
    private var streamingCompactKey: String? {
        streamSession != nil ? "capsule.streaming.typing" : nil
    }
    private func appleEngine() -> AppleSpeechASREngine { asrEngineProvider.appleEngine() }
    private func sherpaEngine() -> SherpaOnnxASREngine { asrEngineProvider.sherpaEngine() }
    private func volcengineEngine() -> VolcengineASREngine { asrEngineProvider.volcengineEngine() }
    private func speechRecognizer() -> SpeechRecognizerController { asrEngineProvider.speechRecognizer() }
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
        asrEngineRegistry: ASREngineRegistry,
        asrEngineProvider: ASREngineProviding
    ) {
        self.audioEngine = audioEngine
        self.capsuleWindow = capsuleWindow
        self.llmRefiner = llmRefiner
        self.textOutputSinkRegistry = textOutputSinkRegistry
        self.volumeController = volumeController
        self.asrEngineRegistry = asrEngineRegistry
        self.asrEngineProvider = asrEngineProvider
        self.recognitionFinalizer = RecognitionResultFinalizer(
            presenter: capsuleWindow,
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

        // AudioAnalyzer 永久订阅 router 16kHz 通道：tap 装上才会有 buffer，不录音期间零开销。
        // (Permanent 16kHz subscription; analyzer only sees buffers when tap is installed.)
        analyzerConsumerID = audioEngine.router.register(format: .voice16k) { [weak self] buffer in
            self?.audioAnalyzer.accept(buffer)
        }
        audioAnalyzer.onSilenceTimeout = { [weak self] in
            self?.stop()
        }
        audioAnalyzer.onBands = { [weak self] bands in
            DispatchQueue.main.async {
                self?.capsuleWindow.updateBands(bands)
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
    func stop() { stopRecording() }
    func stopImmediate(appending punctuation: String?) { stopRecordingImmediate(appending: punctuation) }
    func cancel() { cancelRecording() }

    /// 当前是否正在显示错误胶囊（Whether the error capsule is currently showing）
    var isShowingError: Bool { capsuleWindow.isShowingError }

    /// 关闭错误胶囊（Dismiss the error capsule）
    func dismissError() { capsuleWindow.dismiss() }

    // MARK: - 录音启动（Recording start）

    private func startRecording() {
        guard !isRecording else { return }

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
            guard !self.isRecording else { return }
            guard ready else {
                DebugLog.error("[Session] startRecording: preflight 失败，显示错误胶囊")
                self.capsuleWindow.show()
                self.capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
                return
            }
            self.continueStartRecording()
        }
    }

    private func continueStartRecording() {
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
                if sherpaEngine().isModelLoaded {
                    // 模型已缓存，直接开始录音，不显示加载动画（Model cached, start recording directly without loading animation）
                    capsuleWindow.show(compactStatusKey: streamingCompactKey)
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

        if !audioEngine.start() {
            appleEngine().cancel()
            handleAudioStartFailure()
            return
        }
        // Apple 原生通道（nil-format）：直接拿设备原生 SR 的 buffer 给 SFSpeechRecognizer，
        // 它内部最优重采样到 16kHz。这条路径上 router 不做 SR 转换，零拷贝透传。
        // (Apple consumes native-format buffers; SFSpeechRecognizer resamples internally.)
        activeRouterConsumerID = audioEngine.router.register(format: nil) { [weak self] buffer in
            guard let self,
                  self.recordingGeneration == generation,
                  self.isRecording,
                  self.asrEngineRegistry.isApple(self.currentRecordingEngine)
            else { return }
            self.appleEngine().accept(buffer: buffer)
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
        if !audioEngine.start() {
            sherpaEngine().cancel()
            handleAudioStartFailure()
            return
        }
        // 注册 16kHz 消费者：router 会按需建 AVAudioConverter，把任何设备的原始 SR 重采样到 16kHz 喂 Sherpa。
        // 这是修复"边录音边戴/摘耳机时 sherpa C 层 abort"的关键 —— sherpa 永远只收 16kHz，运行时不再有 SR 突变。
        // (Sherpa always sees 16kHz; eliminates the SR-jump crash on mid-recording route changes.)
        activeRouterConsumerID = audioEngine.router.register(format: .voice16k) { [weak self] buffer in
            guard let self,
                  self.recordingGeneration == generation,
                  self.isRecording,
                  self.asrEngineRegistry.isSherpa(self.currentRecordingEngine)
            else { return }
            self.sherpaEngine().accept(buffer: buffer)
        }
    }

    /// Sherpa 模型未加载时：立即启动录音缓存音频，后台加载模型，加载完成后喂入全部缓存并无缝切换。
    /// (Sherpa model not loaded: start audio immediately and buffer, load model in background, drain buffer when ready.)
    private func startSherpaRecordingWithDeferredModel(generation: Int) {
        sherpaPreload.begin()

        capsuleWindow.showProgress(loc("sherpa.loadingModel"))

        // 1. 立即启动 AudioEngine，下面通过 router 16kHz 消费者拿音频
        if !audioEngine.start() {
            sherpaPreload.cancel()
            handleAudioStartFailure()
            return
        }
        // Sherpa 16kHz 消费者：preload 期间缓存 16k buffer；模型加载完成后由 drain 喂入 sherpa。
        // (Sherpa 16kHz consumer: buffers into preload while model loads; drain feeds them after.)
        activeRouterConsumerID = audioEngine.router.register(format: .voice16k) { [weak self] buffer in
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

        if !audioEngine.start() {
            volcengineEngine().cancel()
            handleAudioStartFailure()
            return
        }
        // 豆包 16kHz 消费者：CloudAudioConverter 看到 16kHz 输入会跳过 resample，仅做 Float32 → Int16。
        // doubaoFallback 也存 16kHz 副本，万一回退到 Apple Speech，Apple 自己会内部重采样。
        // (Doubao 16kHz consumer: CloudAudioConverter skips resample, only does Float→Int16. Fallback uses 16kHz too.)
        activeRouterConsumerID = audioEngine.router.register(format: .voice16k) { [weak self] buffer in
            guard let self,
                  self.recordingGeneration == generation,
                  self.isRecording,
                  self.currentRecordingEngine == VolcengineASRSettings.engineCode
            else { return }
            self.doubaoFallback.appendAudioBufferIfWaiting(buffer, copyBuffer: self.copyAudioBuffer)
            self.volcengineEngine().accept(buffer: buffer)
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
        DebugLog.error("[Session] handleAudioStartFailure: audioEngine.start 返回 false")
        markRecordingStopped()
        doubaoFallback.reset()
        resetLiveInsertionState()
        capsuleWindow.showError(loc("error.audioTapFailed"), dismissAfter: 5)
    }

    private func handleAudioRouteRecoveryFailed() {
        guard isRecording else { return }
        DebugLog.error("[Session] 音频路由变化恢复失败，结束当前录音")
        markRecordingStopped()
        let shouldStopAppleLiveFallback = doubaoFallback.cancel()
        cancelCurrentRecognition(shouldStopAppleLiveFallback: shouldStopAppleLiveFallback)
        audioEngine.abandonAfterRouteRecoveryFailure()
        sherpaPreload.cancel()
        resetLiveInsertionState()
        streamSession?.cancel()
        streamSession = nil
        capsuleWindow.showError(loc("error.audioTapFailed"), dismissAfter: 5)
        delegate?.sessionDidEnd()
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
        // 注销本次录音在 router 上的消费者
        if let id = activeRouterConsumerID {
            audioEngine.router.unregister(id)
            activeRouterConsumerID = nil
        }
        // 清掉 Apple Live Fallback 留下的 switchRequest 消费者（豆包回退路径用）
        audioEngine.clearSwitchedRequest()
        // 重置静音/FFT 滚动状态（下次录音从干净状态开始）
        audioAnalyzer.reset()
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
        // 用 doubao.fallback.withError 包装原始错误：错误文案会带上"已切换到 Apple 语音识别"，
        // 让用户清楚地知道我们已经尝试过 fallback、不是只显示豆包原始报错。
        // (Wrap with the fallback format so the user sees "switched to Apple"; avoids
        //  showing the raw cloud error as if no fallback was attempted.)
        let trimmedOriginal = fallback.originalError.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackError = trimmedOriginal.isEmpty ? nil : loc("doubao.fallback.withError", trimmedOriginal)

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
                    isActive: liveInsertionActive,
                    committedText: liveInsertionCommittedText
                ),
                streamSession: streamSession,
                clearStreamSession: { [weak self] in
                    self?.streamSession = nil
                }
            )
        )
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
}
