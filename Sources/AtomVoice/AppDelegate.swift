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
    private var volumeController: VolumeController!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var oobeWindowController: OOBEWindowController?
    private var selectedRecognitionEngineCode = ASREngineRegistry.appleCode
    private var selectedSherpaPresetID = ""
    private var selectedSherpaRecognitionLanguage = ""
    private var selectedSherpaProvider = ""
    private var pendingSherpaModelRelease = false
    private var sherpaAutoUnloadWorkItem: DispatchWorkItem?
    private var sherpaDownloadCapsuleActive = false
    private var sherpaDownloadCapsuleMessage: String?
    private var sherpaDownloadCapsuleLastUpdate = Date.distantPast
    private var session: RecordingSessionController!

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

        // 全新安装：首次启动跳过权限请求，交给 OOBE 引导用户按需授权
        // (Fresh install: skip permission prompts on first launch — OOBE will guide the user.)
        if AppSettings.hasCompletedOOBE {
            requestPermissions()
        }

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

        session = RecordingSessionController(
            audioEngine: audioEngine,
            capsuleWindow: capsuleWindow,
            llmRefiner: llmRefiner,
            textPostProcessorRegistry: textPostProcessorRegistry,
            textOutputSinkRegistry: textOutputSinkRegistry,
            volumeController: volumeController,
            asrEngineRegistry: asrEngineRegistry
        )
        session.delegate = self

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

        audioEngine.onSilenceTimeout = { [weak self] in self?.session.stop() }

        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in
                guard let self else { return }
                // 错误胶囊显示中：按触发键关闭错误，不重试录音（Error capsule visible: dismiss it without retrying）
                if self.session.isShowingError {
                    self.session.dismissError()
                    return
                }
                let silenceMode = AppSettings.silenceAutoStopEnabled
                if silenceMode {
                    // 切换模式：按一次开始，再按一次手动停止（Toggle mode: press once to start, press again to stop manually）
                    if self.session.isRecording {
                        self.session.stop()
                    } else {
                        self.cancelSherpaAutoUnloadTask()
                        self.session.start()
                    }
                } else {
                    self.cancelSherpaAutoUnloadTask()
                    self.session.start()
                }
            },
            onFnUp: { [weak self] in
                guard let self else { return }
                let silenceMode = AppSettings.silenceAutoStopEnabled
                // 静音模式下松开 Fn 不停止录音（In silence mode, releasing Fn does not stop recording）
                if !silenceMode {
                    self.session.stop()
                }
            }
        )
        fnKeyMonitor.triggerKeyCode = AppSettings.triggerKeyCode
        fnKeyMonitor.onTapDisabled = { [weak self] in
            self?.menuBarController.showAccessibilityWarning()
        }
        // session 通知 fnKeyMonitor 录音状态（Session notifies fnKeyMonitor of recording state）
        session.onRecordingStateChanged = { [weak self] active in
            guard let self else { return }
            self.fnKeyMonitor.isRecording = active
            self.handleRecordingStateChangedForDownloadCapsule(active: active)
        }
        menuBarController.onTriggerKeyChanged = { [weak self] keyCode in
            self?.fnKeyMonitor.triggerKeyCode = keyCode
        }
        // ESC 取消录音，不上屏（ESC cancels recording, no text injection）
        fnKeyMonitor.onEscPressed = { [weak self] in self?.session.cancel() }
        // Space/Backspace 立即上屏，跳过 LLM（Space/Backspace injects text immediately, skipping LLM）
        fnKeyMonitor.onImmediateStop = { [weak self] punctuation in
            self?.session.stopImmediate(appending: punctuation)
        }
        // 全新安装：等 OOBE 完成再启动 tap，避免立刻弹辅助功能权限对话框
        // (Fresh install: defer event tap until OOBE finishes to avoid the early Accessibility prompt.)
        if AppSettings.hasCompletedOOBE {
            fnKeyMonitor.start()
        }

        // 启动 5 秒后静默检查更新，不阻塞启动流程（Silently check for updates 5s after launch, non-blocking）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkForUpdates(silent: true)
        }

        // 监听系统内存压力，仅在内存严重不足时释放模型（Monitor system memory pressure, release model only on critical shortage）
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.session.isRecording else { return }
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
        guard session.isRecording else { return }
        // 静音模式（单击说话）下，切换窗口是正常流程，不取消录音（In silence mode (tap-to-talk), switching windows is normal flow, don't cancel recording）
        let silenceMode = AppSettings.silenceAutoStopEnabled
        if silenceMode { return }
        // 长按模式下切换了前台应用，取消本次录音（In hold-to-talk mode, switched frontmost app, cancel this recording）
        session.cancel()
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

        if session.isRecording && asrEngineRegistry.isSherpa(session.currentRecordingEngine) {
            pendingSherpaModelRelease = true
            return
        }

        releaseSherpaModelsIfNeeded()
    }

    private func handleSherpaSelectionChange() {
        guard sherpaASREngine != nil else { return }

        if session.isRecording && asrEngineRegistry.isSherpa(session.currentRecordingEngine) {
            pendingSherpaModelRelease = true
            DebugLog.info("[AppDelegate] Sherpa 预设已切换，当前录音结束后释放旧模型")
            return
        }

        DebugLog.info("[AppDelegate] Sherpa 预设已切换，释放旧模型")
        releaseSherpaModelsIfNeeded()
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

    fileprivate func cancelSherpaAutoUnloadTask() {
        sherpaAutoUnloadWorkItem?.cancel()
        sherpaAutoUnloadWorkItem = nil
    }

    private func scheduleSherpaAutoUnloadIfNeeded() {
        cancelSherpaAutoUnloadTask()
        guard sherpaAutoUnloadEnabled(),
              !session.isRecording,
              selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
              sherpaASREngine?.isModelLoaded == true else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sherpaAutoUnloadWorkItem = nil
            guard !self.session.isRecording,
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

    /// 录音结束后的 Sherpa 清理（条件释放 + 重新调度 idle 卸载）。
    /// (Post-recording Sherpa cleanup — conditional release + reschedule idle unload.)
    private func performPostRecordingSherpaCleanup() {
        releaseSherpaModelsAfterRecordingIfNeeded()
        scheduleSherpaAutoUnloadIfNeeded()
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

    static func showSherpaDownloadCapsule(_ message: String) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.updateSherpaDownloadCapsule(message, force: false)
    }

    static func finishSherpaDownloadCapsule(success: Bool, error: String?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.sherpaDownloadCapsuleActive = false
        appDelegate.sherpaDownloadCapsuleMessage = nil
        if appDelegate.session.isRecording { return }
        if success {
            appDelegate.capsuleWindow.updateText(loc("sherpa.download.complete"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak appDelegate] in
                appDelegate?.capsuleWindow.dismiss()
            }
        } else {
            appDelegate.capsuleWindow.showError(loc("sherpa.download.failed", error ?? "Unknown error"), dismissAfter: 6)
        }
    }

    private func updateSherpaDownloadCapsule(_ message: String, force: Bool) {
        sherpaDownloadCapsuleActive = true
        sherpaDownloadCapsuleMessage = message
        guard !session.isRecording else { return }

        let now = Date()
        guard force || now.timeIntervalSince(sherpaDownloadCapsuleLastUpdate) >= 0.25 else { return }
        sherpaDownloadCapsuleLastUpdate = now
        capsuleWindow.showDownloadProgress(message)
    }

    private func handleRecordingStateChangedForDownloadCapsule(active: Bool) {
        guard sherpaDownloadCapsuleActive else { return }
        if active {
            capsuleWindow.dismiss()
        } else if let message = sherpaDownloadCapsuleMessage {
            updateSherpaDownloadCapsule(message, force: true)
        }
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

    // MARK: - Sherpa 模型下载

    /// 启动时一次性迁移：清理旧 ready 标记；若 sherpaModelPresetID 指向未下载 preset 但同语言下已有别的 preset 已下载，则自动切换。
    /// (One-shot migration at launch: remove deprecated ready flag; if sherpaModelPresetID points to an undownloaded preset but a different one in the same language is downloaded, auto-switch.)
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
                // OOBE 完成后再启动 tap 与权限请求；start 是幂等的
                // (Start tap & request perms now; start() is idempotent so repeated OOBE runs are safe.)
                self.fnKeyMonitor.start()
                self.requestPermissions()
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

    /// OOBE 完成后用：触发已存在的 Sherpa 下载提示流程。
    /// (Trigger existing Sherpa download prompt after OOBE.)
    fileprivate func promptSherpaDownloadPublic() {
        promptSherpaDownload()
    }

    private func startSherpaDownload() {
        if SherpaModelDownloader.isReady() { return }

        let downloader = SherpaModelDownloader.shared

        AppDelegate.showSherpaDownloadCapsule(loc("sherpa.downloading.start"))

        downloader.addObserver(
            progress: { [weak self] _, _, _, message in
                guard self != nil else { return }
                AppDelegate.showSherpaDownloadCapsule(message)
            },
            complete: { [weak self] success, error in
                guard self != nil else { return }
                AppDelegate.finishSherpaDownloadCapsule(success: success, error: error)
            }
        )

        _ = downloader.startDownload()
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
}

// MARK: - RecordingSessionDelegate

extension AppDelegate: RecordingSessionDelegate {
    func sessionRequiresAppleASREngine() -> AppleSpeechASREngine {
        ensureAppleASREngine()
    }

    func sessionRequiresSherpaASREngine() -> SherpaOnnxASREngine {
        ensureSherpaASREngine()
    }

    func sessionRequiresVolcengineASREngine() -> VolcengineASREngine {
        ensureVolcengineASREngine()
    }

    func sessionRequiresSpeechRecognizer() -> SpeechRecognizerController {
        ensureSpeechRecognizer()
    }

    func sessionRequiresSherpaModelDownload(redownload: Bool) {
        if redownload {
            promptSherpaReDownload()
        } else {
            promptSherpaDownload()
        }
    }

    func sessionDidEnd() {
        performPostRecordingSherpaCleanup()
    }
}
