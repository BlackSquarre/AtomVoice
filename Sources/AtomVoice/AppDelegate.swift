import Cocoa
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let asrEngineRegistry = ASREngineRegistry.shared
    private var menuBarController: MenuBarController!
    private var fnKeyMonitor: FnKeyMonitor!
    private var audioEngine: AudioEngineController!
    private var speechRecognizer: SpeechRecognizerController?
    private var sherpaRecognizer: SherpaOnnxRecognizerController?
    private var volcengineProvider: VolcengineASRProvider?
    private var cloudRecognizer: CloudASRRecognizerController?
    private var appleASREngine: AppleSpeechASREngine?
    private var sherpaASREngine: SherpaOnnxASREngine?
    private var volcengineASREngine: VolcengineASREngine?
    private var capsuleWindow: CapsuleWindowController!
    private var textInjector: TextInjector!
    private var llmRefiner: LLMRefiner!
    private var textPostProcessorRegistry: TextPostProcessorRegistry!
    private var textOutputSinkRegistry: TextOutputSinkRegistry!
    private var activeOutputSink: TextOutputSink { textOutputSinkRegistry.current() }
    private var streamSession: TextStreamSession?

    /// 流式 sink 启用时使用的紧凑状态 key（"正在输入"）；非流式返回 nil
    /// (Compact status key for streaming sink mode — nil otherwise)
    private var streamingCompactKey: String? {
        streamSession != nil ? "capsule.streaming.typing" : nil
    }
    private var volumeController: VolumeController!
    private let doubaoFallback = DoubaoFallbackCoordinator()
    private var appleLiveFallback: AppleLiveFallbackStrategy!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var oobeWindowController: OOBEWindowController?
    private var selectedRecognitionEngineCode = ASREngineRegistry.appleCode
    private var selectedSherpaPresetID = ""
    private var selectedSherpaRecognitionLanguage = ""
    private var selectedSherpaProvider = ""
    private var pendingSherpaModelRelease = false
    private var sherpaAutoUnloadWorkItem: DispatchWorkItem?
    private var isRecording = false
    private var currentRecordingEngine = ASREngineRegistry.appleCode
    private var liveInsertionActive = false
    private var liveInsertionCommittedText = ""
    private var liveInsertionLatestText = ""
    private var liveInsertionPasteInFlight = false
    private var recordingGeneration = 0
    // Sherpa 模型预加载协调器：缓存音频 + 加载完成后排空（详见 SherpaPreloadCoordinator）
    // (Sherpa preload coordinator: caches audio and drains after model load — see SherpaPreloadCoordinator)
    private let sherpaPreload = SherpaPreloadCoordinator()

    deinit {
        memoryPressureSource?.cancel()
        sherpaAutoUnloadWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherRunningInstances()

        AppSettings.registerDefaults()
        if !AppSettings.doubaoASRLowLatencyDefaultApplied {
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.doubaoASREnableNonstream)
            AppSettings.doubaoASRLowLatencyDefaultApplied = true
        }
        selectedRecognitionEngineCode = AppSettings.normalizedRecognitionEngine
        selectedSherpaPresetID = AppSettings.sherpaModelPresetID
        selectedSherpaRecognitionLanguage = SherpaModelPreset.recognitionLanguage
        selectedSherpaProvider = AppSettings.sherpaProvider
        // 启动时异步探测 GitHub 可达性，结果缓存供下载流程参考；不阻塞主线程
        // (Async probe GitHub reachability at launch; cached for download flow, no main-thread block)
        SherpaModelPreset.probeMirrorAsync()

        // 清理已废弃的 sherpaModelsReady 标记 + 修复 sherpaModelPresetID 指向未下载模型的状态
        // (Cleanup deprecated sherpaModelsReady flag + heal sherpaModelPresetID pointing to undownloaded preset)
        Self.migrateSherpaPresetIfNeeded()

        requestPermissions()

        llmRefiner = LLMRefiner()
        textInjector = TextInjector()
        capsuleWindow = CapsuleWindowController()
        audioEngine = AudioEngineController()
        textPostProcessorRegistry = TextPostProcessorRegistry(processors: [
            SherpaPunctuationProcessor(registry: asrEngineRegistry) { [weak self] text in
                self?.ensureSherpaASREngine().punctuate(text)
            },
            HeuristicPunctuationProcessor(),
        ])
        // 流式直接上屏（StreamingInjectSink）暂时不暴露给用户：iTerm2/Safari 等场景下 AX 写入不可靠
        // 已知问题与重启方法见 docs/streaming-text-output.md。源码保留在 TextOutputSink.swift / AXTextWriter.swift
        // (StreamingInjectSink temporarily not registered — AX writes unreliable in iTerm2/Safari etc.
        //  See docs/streaming-text-output.md for known issues and how to re-enable.)
        textOutputSinkRegistry = TextOutputSinkRegistry(sinks: [
            PasteboardInjectSink(injector: textInjector),
            // StreamingInjectSink(injector: textInjector),  // 待续 (TODO)
        ])
        volumeController = VolumeController()
        appleLiveFallback = AppleLiveFallbackStrategy(
            audioEngine: audioEngine,
            fallback: doubaoFallback,
            speechRecognizerProvider: { [unowned self] in self.ensureSpeechRecognizer() }
        )

        menuBarController = MenuBarController(
            onLanguageChanged: { [weak self] in
                self?.ensureAppleASREngine().updateLanguage()
            },
            llmRefiner: llmRefiner,
            asrEngineRegistry: asrEngineRegistry,
            textOutputSinkRegistry: textOutputSinkRegistry
        )
        menuBarController.onSherpaDownloadRequested = { [weak self] in
            self?.startSherpaDownload()
        }

        audioEngine.onSilenceTimeout = { [weak self] in self?.stopRecording() }

        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in
                guard let self else { return }
                let silenceMode = AppSettings.silenceAutoStopEnabled
                if silenceMode {
                    // 切换模式：按一次开始，再按一次手动停止（Toggle mode: press once to start, press again to stop manually）
                    if self.isRecording {
                        self.stopRecording()
                    } else {
                        self.startRecording()
                    }
                } else {
                    self.startRecording()
                }
            },
            onFnUp: { [weak self] in
                guard let self else { return }
                let silenceMode = AppSettings.silenceAutoStopEnabled
                // 静音模式下松开 Fn 不停止录音（In silence mode, releasing Fn does not stop recording）
                if !silenceMode {
                    self.stopRecording()
                }
            }
        )
        fnKeyMonitor.triggerKeyCode = AppSettings.triggerKeyCode
        fnKeyMonitor.onTapDisabled = { [weak self] in
            self?.menuBarController.showAccessibilityWarning()
        }
        menuBarController.onTriggerKeyChanged = { [weak self] keyCode in
            self?.fnKeyMonitor.triggerKeyCode = keyCode
        }
        // ESC 取消录音，不上屏（ESC cancels recording, no text injection）
        fnKeyMonitor.onEscPressed = { [weak self] in self?.cancelRecording() }
        // Space/Backspace 立即上屏，跳过 LLM（Space/Backspace injects text immediately, skipping LLM）
        fnKeyMonitor.onImmediateStop = { [weak self] punctuation in
            self?.stopRecordingImmediate(appending: punctuation)
        }
        fnKeyMonitor.start()

        // 启动 5 秒后静默检查更新，不阻塞启动流程（Silently check for updates 5s after launch, non-blocking）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkForUpdates(silent: true)
        }

        // 监听系统内存压力，仅在内存严重不足时释放模型（Monitor system memory pressure, release model only on critical shortage）
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.isRecording else { return }
            DebugLog.info("[AppDelegate] 系统内存压力，释放 Sherpa 模型")
            self.releaseSherpaModelsIfNeeded()
        }
        memoryPressureSource?.resume()

        // 首次启动展示 OOBE 引导（Show first-launch OOBE on cold start）
        if !AppSettings.hasCompletedOOBE {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }

        // 监听前台应用切换：录音期间切换程序则取消录音（Monitor active app change: cancel recording when switching apps）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recognitionEngineDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    private func terminateOtherRunningInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }
        guard !otherApps.isEmpty else { return }

        // 菜单栏应用不应该多开；新实例启动时清理旧实例，避免出现多个状态栏菜单（Menu bar apps should not run multiple instances; terminate old ones to avoid duplicate status bar menus）
        otherApps.forEach { app in
            DebugLog.info("[AppDelegate] 正在退出旧实例 pid=\(app.processIdentifier)")
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            otherApps.filter { !$0.isTerminated }.forEach { app in
                DebugLog.info("[AppDelegate] 旧实例未正常退出，强制结束 pid=\(app.processIdentifier)")
                app.forceTerminate()
            }
        }
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard isRecording else { return }
        // 静音模式（单击说话）下，切换窗口是正常流程，不取消录音（In silence mode (tap-to-talk), switching windows is normal flow, don't cancel recording）
        let silenceMode = AppSettings.silenceAutoStopEnabled
        if silenceMode { return }
        // 长按模式下切换了前台应用，取消本次录音（In hold-to-talk mode, switched frontmost app, cancel this recording）
        cancelRecording()
    }

    @objc private func recognitionEngineDefaultsDidChange() {
        let newCode = AppSettings.normalizedRecognitionEngine
        let previousCode = selectedRecognitionEngineCode
        selectedRecognitionEngineCode = newCode

        let newSherpaPresetID = AppSettings.sherpaModelPresetID
        let newSherpaRecognitionLanguage = SherpaModelPreset.recognitionLanguage
        let newSherpaProvider = AppSettings.sherpaProvider
        let didChangeSherpaSelection =
            newSherpaPresetID != selectedSherpaPresetID ||
            newSherpaRecognitionLanguage != selectedSherpaRecognitionLanguage ||
            newSherpaProvider != selectedSherpaProvider
        selectedSherpaPresetID = newSherpaPresetID
        selectedSherpaRecognitionLanguage = newSherpaRecognitionLanguage
        selectedSherpaProvider = newSherpaProvider

        guard newCode != previousCode else {
            if didChangeSherpaSelection {
                handleSherpaSelectionChange()
            }
            updateSherpaAutoUnloadConfiguration()
            return
        }

        guard asrEngineRegistry.isSherpa(previousCode), !asrEngineRegistry.isSherpa(newCode) else {
            if didChangeSherpaSelection {
                handleSherpaSelectionChange()
            }
            updateSherpaAutoUnloadConfiguration()
            return
        }

        if isRecording && asrEngineRegistry.isSherpa(currentRecordingEngine) {
            pendingSherpaModelRelease = true
            return
        }

        releaseSherpaModelsIfNeeded()
    }

    private func handleSherpaSelectionChange() {
        guard sherpaASREngine != nil else { return }

        if isRecording && asrEngineRegistry.isSherpa(currentRecordingEngine) {
            pendingSherpaModelRelease = true
            DebugLog.info("[AppDelegate] Sherpa 预设已切换，当前录音结束后释放旧模型")
            return
        }

        DebugLog.info("[AppDelegate] Sherpa 预设已切换，释放旧模型")
        releaseSherpaModelsIfNeeded()
    }

    private func asrEngine(for code: String) -> ASREngine {
        switch code {
        case VolcengineASRSettings.engineCode:
            return ensureVolcengineASREngine()
        case ASREngineRegistry.sherpaCode:
            return ensureSherpaASREngine()
        default:
            return ensureAppleASREngine()
        }
    }

    private func ensureSpeechRecognizer() -> SpeechRecognizerController {
        if let speechRecognizer { return speechRecognizer }
        let recognizer = SpeechRecognizerController()
        speechRecognizer = recognizer
        return recognizer
    }

    private func ensureSherpaRecognizer() -> SherpaOnnxRecognizerController {
        if let sherpaRecognizer { return sherpaRecognizer }
        let recognizer = SherpaOnnxRecognizerController()
        sherpaRecognizer = recognizer
        return recognizer
    }

    private func ensureVolcengineProvider() -> VolcengineASRProvider {
        if let volcengineProvider { return volcengineProvider }
        let provider = VolcengineASRProvider()
        volcengineProvider = provider
        return provider
    }

    private func ensureCloudRecognizer() -> CloudASRRecognizerController {
        if let cloudRecognizer { return cloudRecognizer }
        let recognizer = CloudASRRecognizerController(provider: ensureVolcengineProvider())
        cloudRecognizer = recognizer
        return recognizer
    }

    private func ensureAppleASREngine() -> AppleSpeechASREngine {
        if let appleASREngine { return appleASREngine }
        let engine = AppleSpeechASREngine(recognizer: ensureSpeechRecognizer())
        appleASREngine = engine
        return engine
    }

    private func ensureSherpaASREngine() -> SherpaOnnxASREngine {
        if let sherpaASREngine { return sherpaASREngine }
        let engine = SherpaOnnxASREngine(recognizer: ensureSherpaRecognizer())
        sherpaASREngine = engine
        return engine
    }

    private func ensureVolcengineASREngine() -> VolcengineASREngine {
        if let volcengineASREngine { return volcengineASREngine }
        let engine = VolcengineASREngine(provider: ensureVolcengineProvider(), recognizer: ensureCloudRecognizer())
        volcengineASREngine = engine
        return engine
    }

    private func sherpaAutoUnloadEnabled() -> Bool {
        AppSettings.sherpaAutoUnloadEnabled
    }

    private func sherpaAutoUnloadDelay() -> TimeInterval {
        TimeInterval(AppSettings.sherpaAutoUnloadIdleMinutes * 60)
    }

    private func cancelSherpaAutoUnloadTask() {
        sherpaAutoUnloadWorkItem?.cancel()
        sherpaAutoUnloadWorkItem = nil
    }

    private func scheduleSherpaAutoUnloadIfNeeded() {
        cancelSherpaAutoUnloadTask()
        guard sherpaAutoUnloadEnabled(),
              !isRecording,
              selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
              sherpaASREngine?.isModelLoaded == true else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sherpaAutoUnloadWorkItem = nil
            guard !self.isRecording,
                  self.selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
                  self.sherpaASREngine?.isModelLoaded == true else { return }
            DebugLog.info("[AppDelegate] Sherpa 模型空闲超时，自动释放本地模型")
            self.releaseSherpaModelsIfNeeded()
        }
        sherpaAutoUnloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + sherpaAutoUnloadDelay(), execute: workItem)
    }

    private func updateSherpaAutoUnloadConfiguration() {
        if selectedRecognitionEngineCode != ASREngineRegistry.sherpaCode || !sherpaAutoUnloadEnabled() {
            cancelSherpaAutoUnloadTask()
        }
        scheduleSherpaAutoUnloadIfNeeded()
    }

    private func releaseSherpaModelsIfNeeded() {
        cancelSherpaAutoUnloadTask()
        pendingSherpaModelRelease = false
        guard let sherpaASREngine else { return }
        if sherpaASREngine.isModelLoaded {
            DebugLog.info("[AppDelegate] 释放 Sherpa 本地模型")
            sherpaASREngine.releaseModels()
        }
        self.sherpaASREngine = nil
        self.sherpaRecognizer = nil
        DebugLog.info("[AppDelegate] 已释放 Sherpa 引擎实例")
    }

    private func releaseSherpaModelsAfterRecordingIfNeeded() {
        guard pendingSherpaModelRelease else { return }
        releaseSherpaModelsIfNeeded()
    }

    // MARK: - Window activation helpers

    /// 在 LSUIElement=true 的菜单栏应用里，先把窗口移动到当前 Space，
    /// 再显示和激活，避免在全屏 app 中打开窗口时跳回桌面。
    /// (In a LSUIElement=true menu bar app, move the window to the current Space first,
    /// then show and activate it, to avoid jumping back to the desktop when opening from a fullscreen app.)
    static func bringToFront(_ window: NSWindow) {
        bringToFront(window, transient: false)
    }

    /// 从状态栏菜单打开的辅助窗口应留在当前 Space，包括其他 app 的全屏 Space。
    /// (Auxiliary windows opened from the status bar menu should stay in the current Space, including fullscreen Spaces of other apps.)
    static func bringToFrontInCurrentSpace(_ window: NSWindow) {
        bringToFront(window, transient: true)
    }

    private static func bringToFront(_ window: NSWindow, transient: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        var behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if transient { behavior.insert(.transient) }
        window.collectionBehavior.formUnion(behavior)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 菜单收起后一帧再确认一次，避免状态栏菜单焦点覆盖窗口焦点（Re-confirm one frame after menu dismisses, to prevent status bar menu focus from overriding window focus）
        DispatchQueue.main.async {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @discardableResult
    static func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary, .transient])
        let response = alert.runModal()
        resetActivationIfNeeded()
        return response
    }

    /// 窗口关闭时调用：若已无其他普通窗口可见，恢复 accessory 策略。
    /// (Called when a window closes: if no other regular windows are visible, restore accessory activation policy.)
    static func resetActivationIfNeeded(closing: NSWindow? = nil) {
        let hasOther = NSApp.windows.contains { window in
            if let closing, window === closing { return false }
            return window.isVisible && window.styleMask.contains(.titled)
        }
        if !hasOther { NSApp.setActivationPolicy(.accessory) }
    }

    private static func activateForForegroundInteraction() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let currentApp = NSRunningApplication.current
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp.processIdentifier != currentApp.processIdentifier {
            currentApp.activate(from: frontmostApp, options: [.activateAllWindows])
        } else {
            currentApp.activate(options: [.activateAllWindows])
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.mic.title")
                    alert.informativeText = loc("permission.mic.message")
                    AppDelegate.runModalAlert(alert)
                }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.speech.title")
                    alert.informativeText = loc("permission.speech.message")
                    AppDelegate.runModalAlert(alert)
                }
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        cancelSherpaAutoUnloadTask()

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
                    self?.promptSherpaDownload()
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
        fnKeyMonitor.isRecording = true
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
        DebugLog.info("[AppDelegate] startRecording: lowerVolume=\(lowerVolume), vc=\(volumeController != nil ? "yes" : "nil")")
        if lowerVolume {
            volumeController.saveAndDecreaseVolume()
        }

        DispatchQueue.main.async { [self] in
            guard isRecording, recordingGeneration == generation else { return }

            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                startDoubaoRecording(generation: generation)
            } else if asrEngineRegistry.isSherpa(currentRecordingEngine) {
                capsuleWindow.show(compactStatusKey: streamingCompactKey)
                if sherpaASREngine?.isModelLoaded == true {
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
        if let error = ensureAppleASREngine().start(
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
                self.ensureAppleASREngine().accept(buffer: buffer)
            }
        ) {
            ensureAppleASREngine().cancel()
            handleAudioStartFailure()
        }
    }

    private func startSherpaRecordingAfterModelLoad(generation: Int) {
        if let error = ensureSherpaASREngine().start(onResult: { [weak self] text, _ in
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
                self.ensureSherpaASREngine().accept(buffer: buffer)
            }
        ) {
            ensureSherpaASREngine().cancel()
            handleAudioStartFailure()
        }
    }

    /// Sherpa 模型未加载时：立即启动录音缓存音频，后台加载模型，加载完成后喂入全部缓存并无缝切换（When Sherpa model is not loaded: start recording immediately and buffer audio, load model in background, feed all buffered audio and switch seamlessly after load）
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
                    self.ensureSherpaASREngine().accept(buffer: buffer)
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
            let error = self.ensureSherpaASREngine().start(onResult: { [weak self] text, _ in
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
                        self?.ensureSherpaASREngine().accept(buffer: buf)
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
        DebugLog.info("[AppDelegate] 启动豆包录音, generation=\(generation)")
        doubaoFallback.beginWaitingForFirstResult()
        capsuleWindow.show(compactStatusKey: streamingCompactKey)
        capsuleWindow.showRecording()
        // 延迟一帧挂扫光，表示正在连接（Delay one frame to apply shimmer, indicating connecting）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingGeneration == generation, self.isRecording else { return }
            self.capsuleWindow.applyShimmerToCapsule()
        }
        if let error = ensureVolcengineASREngine().start(onResult: { [weak self] text, _ in
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
                self.ensureVolcengineASREngine().accept(buffer: buffer)
            }
        ) {
            ensureVolcengineASREngine().cancel()
            handleAudioStartFailure()
        }
    }

    private func handleDoubaoRecognitionError(_ message: String) {
        guard currentRecordingEngine == VolcengineASRSettings.engineCode else { return }
        let isBenignSilenceError = appleLiveFallback.isBenignSilenceError(
            message,
            cloudCurrentText: ensureVolcengineASREngine().currentText
        )
        let visibleError = isBenignSilenceError ? "" : message
        guard doubaoFallback.recordError(visibleError, currentText: ensureVolcengineASREngine().currentText) else { return }

        DebugLog.error("[AppDelegate] 豆包识别错误: \(message), isRecording=\(isRecording)")

        ensureVolcengineASREngine().cancel()
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

        DebugLog.info("[AppDelegate] 启动 Apple 实时回退 (豆包错误后)")
        capsuleWindow.stopShimmer()
        capsuleWindow.updateText(initialText)
    }

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

    private func updateRecognizedText(_ text: String) {
        capsuleWindow.updateText(text)
        streamSession?.update(currentText: text)
    }

    private func markRecordingStopped() {
        isRecording = false
        fnKeyMonitor.isRecording = false
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
            return ensureSherpaASREngine().stopSynchronously()
        }
        return ensureAppleASREngine().stopSynchronously()
    }

    private func cancelCurrentRecognition(shouldStopAppleLiveFallback: Bool = false) {
        if currentRecordingEngine == VolcengineASRSettings.engineCode {
            ensureVolcengineASREngine().cancel()
            if shouldStopAppleLiveFallback {
                _ = ensureSpeechRecognizer().stop()
            }
        } else if asrEngineRegistry.isSherpa(currentRecordingEngine) {
            ensureSherpaASREngine().cancel()
        } else {
            ensureAppleASREngine().cancel()
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

    private func handleSherpaStartFailure(_ error: String, stopAudioEngine: Bool = false) {
        if stopAudioEngine {
            audioEngine.stop()
        }
        markRecordingStopped()
        DebugLog.error("[SherpaOnnx] 模型加载失败: \(error)")

        let failureKind = ensureSherpaASREngine().lastStartFailureKind
        let needsRedownload =
            failureKind == .missingRuntime ||
            failureKind == .missingModel ||
            failureKind == .invalidModel

        if needsRedownload {
            SherpaModelDownloader.printMissingRequiredFiles()
            capsuleWindow.showError(error, dismissAfter: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.promptSherpaReDownload()
            }
        } else {
            // 文件存在但加载失败（dylib 问题等），只报错（Files exist but load failed (e.g. dylib issue), only show error）
            capsuleWindow.showError(error, dismissAfter: 6)
        }
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

    /// Doubao 收尾路径：若 fallback 已激活或已记录错误，取消云端连接并走 Apple fallback 完成；
    /// 返回 true 表示已接管，调用方应直接 return。
    /// (Doubao end-of-recording: if fallback is active or has recorded error, cancel cloud and finish via Apple fallback;
    ///  returns true when this branch took over — caller should return.)
    private func consumeDoubaoFallbackIfNeeded(
        generation: Int,
        appendingImmediatePunctuation punctuation: String? = nil
    ) -> Bool {
        guard doubaoFallback.currentError != nil || doubaoFallback.isAppleLiveActive else {
            return false
        }
        ensureVolcengineASREngine().cancel()
        finishDoubaoRecordingWithAppleFallback(
            generation: generation,
            originalError: doubaoFallback.currentError ?? "",
            appendingImmediatePunctuation: punctuation
        )
        return true
    }

    /// 录音结束后的 Sherpa 清理（条件释放 + 重新调度 idle 卸载）
    /// (Post-recording Sherpa cleanup — conditional release + reschedule idle unload)
    private func performPostRecordingSherpaCleanup() {
        releaseSherpaModelsAfterRecordingIfNeeded()
        scheduleSherpaAutoUnloadIfNeeded()
    }

    private func stopRecording() {
        guard isRecording else { return }
        let generation = recordingGeneration
        markRecordingStopped()

        DispatchQueue.main.async { [self] in
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                audioEngine.stop()
                if consumeDoubaoFallbackIfNeeded(generation: generation) { return }
                ensureVolcengineASREngine().stop { [weak self] recognizedText, errorMsg in
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

    private func finishDoubaoRecordingWithAppleFallback(
        generation: Int,
        originalError: String,
        fallbackTextIfAppleEmpty: String = "",
        appendingImmediatePunctuation punctuation: String? = nil
    ) {
        let fallback = doubaoFallback.makeFallbackSnapshot(
            originalError: originalError,
            fallbackTextIfAppleEmpty: fallbackTextIfAppleEmpty,
            stopLiveFallback: { [weak self] in self?.ensureSpeechRecognizer().stop() ?? "" }
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
        ensureSpeechRecognizer().recognize(buffers: fallback.buffers, onResult: { [weak self] text, _ in
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
        defer { performPostRecordingSherpaCleanup() }
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

    /// 流式 sink 模式下的录音结束流程：替换/补标点/调 LLM，然后关闭 session
    /// (Recording-finish flow under streaming sink: replace / add punctuation / run LLM, then close the session)
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

    // MARK: - Sherpa 模型下载

    /// 启动时一次性迁移：清理旧 ready 标记；若 sherpaModelPresetID 指向未下载 preset 但同语言下已有别的 preset 已下载，则自动切换
    /// (One-shot migration at launch: remove deprecated ready flag; if sherpaModelPresetID points to an undownloaded preset but a different one in the same language is downloaded, auto-switch)
    private static func migrateSherpaPresetIfNeeded() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "sherpaModelsReady")

        guard let savedID = defaults.string(forKey: AppSettings.Keys.sherpaModelPresetID),
              let preset = SherpaModelPreset.allPresets.first(where: { $0.id == savedID }),
              !preset.isDownloaded else { return }

        let lang = SherpaModelPreset.recognitionLanguage
        let pool = SherpaModelPreset.presets(forRecognitionLanguage: lang)
        if let alt = pool.first(where: { $0.isDownloaded }) {
            defaults.set(alt.id, forKey: AppSettings.Keys.sherpaModelPresetID)
            DebugLog.info("[SherpaOnnx] 启动迁移: \(savedID) 未下载，自动切到已下载的 \(alt.id)")
        }
        // 若同语言下都没有已下载的，保留原值；下次切到 sherpa 引擎时会触发下载提示
        // (If nothing downloaded in this language, keep original; next sherpa switch will prompt download)
    }

    /// 展示 OOBE 引导窗口（Show OOBE onboarding window）
    func showOOBE() {
        if oobeWindowController == nil {
            oobeWindowController = OOBEWindowController()
            oobeWindowController?.onFinish = { [weak self] engine, triggerKey in
                guard let self else { return }
                // 同步触发键到 FnKeyMonitor（Sync trigger key to FnKeyMonitor）
                self.fnKeyMonitor.triggerKeyCode = triggerKey
                // 完成后按选中引擎触发后续配置（After finish, trigger follow-up by chosen engine）
                self.menuBarController.rebuildMenuPublic()
                switch engine {
                case ASREngineRegistry.sherpaCode:
                    if !SherpaModelDownloader.isReady() {
                        self.promptSherpaDownloadPublic()
                    }
                case VolcengineASRSettings.engineCode:
                    self.menuBarController.openDoubaoSettingsFromOutside()
                default:
                    break
                }
                self.oobeWindowController = nil
            }
        }
        oobeWindowController?.showWindow()
    }

    /// OOBE 完成后用：触发已存在的 Sherpa 下载提示流程
    /// (Trigger existing Sherpa download prompt after OOBE)
    fileprivate func promptSherpaDownloadPublic() {
        promptSherpaDownload()
    }

    private func startSherpaDownload() {
        guard !SherpaModelDownloader.shared.isDownloading else { return }
        if SherpaModelDownloader.isReady() { return }

        let downloader = SherpaModelDownloader.shared

        // 显示胶囊，不显示波形（Show capsule without waveform）
        capsuleWindow.show(showRecordingTimer: false)
        capsuleWindow.showProgress(loc("sherpa.downloading.start"))

        downloader.addObserver(
            progress: { [weak self] _, _, _, message in
                self?.capsuleWindow.updateText(message)
            },
            complete: { [weak self] success, error in
                guard let self else { return }
                if success {
                    self.capsuleWindow.updateText(loc("sherpa.download.complete"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.capsuleWindow.dismiss()
                    }
                } else {
                    self.capsuleWindow.showError(loc("sherpa.download.failed", error ?? "Unknown error"), dismissAfter: 6)
                }
            }
        )

        downloader.startDownload()
    }

    private func promptSherpaDownload() {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.download.title")
        alert.informativeText = loc("sherpa.download.message")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("sherpa.download.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))
        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            startSherpaDownload()
        }
    }

    private func promptSherpaReDownload() {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.download.title")
        alert.informativeText = loc("sherpa.redownload.message")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("sherpa.download.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))
        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            startSherpaDownload()
        }
    }

    /// ESC 取消录音：停止一切，不注入文字（ESC cancels recording: stop everything, no text injection）
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
            performPostRecordingSherpaCleanup()
        }
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入（Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly）
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
                recognizedText = ensureVolcengineASREngine().currentText
                ensureVolcengineASREngine().cancel()
            } else {
                recognizedText = stopCurrentLocalASREngineSynchronously()
                audioEngine.stop()
            }
            doubaoFallback.reset()
            finishImmediateRecording(with: recognizedText, appending: punctuation)
        }
    }

    private func finishImmediateRecording(with recognizedText: String, appending punctuation: String?, errorMsg: String? = nil) {
        defer { performPostRecordingSherpaCleanup() }
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

    private func textByAppendingImmediatePunctuation(_ punctuation: String?, to text: String) -> String {
        guard let punctuation, !punctuation.isEmpty else { return text }
        return removingTrailingSentencePunctuation(from: text) + punctuation
    }

    private func processedTextForFinalResult(_ rawText: String, isImmediateFinish: Bool = false) -> String {
        let processedText = applyAutoPunctuation(to: rawText, isImmediateFinish: isImmediateFinish)
        if processedText != rawText {
            capsuleWindow.updateText(processedText)
        }
        return processedText
    }

    private func shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: Bool) -> Bool {
        guard AppSettings.llmEnabled, !AppSettings.llmAPIKey.isEmpty else { return false }
        return !(skipWhenLiveInsertionCommitted && !liveInsertionCommittedText.isEmpty)
    }

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
