import Cocoa

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstance = SingleInstanceController()
    private let asrEngineRegistry = ASREngineRegistry.shared
    private let asrEngineProvider = ASREngineProvider()
    private var menuBarController: MenuBarController!
    private var fnKeyMonitor: FnKeyMonitor!
    private var headphoneCoordinator: HeadphoneInputCoordinator!
    private var audioEngine: AudioEngineController!
    private var capsuleWindow: CapsuleWindowController!
    private var textInjector: TextInjector!
    private var llmRefiner: LLMRefiner!
    private var textPostProcessorRegistry: TextPostProcessorRegistry!
    private var textOutputSinkRegistry: TextOutputSinkRegistry!
    private var volumeController: VolumeController!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
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

    public override init() {
        super.init()
    }

    deinit {
        memoryPressureSource?.cancel()
        sherpaAutoUnloadWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        singleInstance.releaseSingleInstance(currentPID: ProcessInfo.processInfo.processIdentifier)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        singleInstance.claimSingleInstance(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            currentExecutableURL: Bundle.main.executableURL?.standardizedFileURL
        )

        // 安装最小主菜单（含 Edit），让设置窗口的 NSTextField 能响应 Cmd+C/V/X/A
        // (Install minimal main menu with Edit so settings-window text fields accept Cmd+C/V/X/A.)
        MainMenuInstaller.install()

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
        capsuleWindow.onRecordingClick = { [weak self] in
            guard let self, self.session.isRecording else { return }
            self.session.stop()
        }
        audioEngine = AudioEngineController()
        textPostProcessorRegistry = TextPostProcessorRegistry(processors: [
            SherpaPunctuationProcessor(registry: asrEngineRegistry) { [weak self] text in
                self?.asrEngineProvider.sherpaEngine().punctuate(text)
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
            asrEngineRegistry: asrEngineRegistry,
            asrEngineProvider: asrEngineProvider
        )
        session.delegate = self

        menuBarController = MenuBarController(
            onLanguageChanged: { [weak self] in
                self?.asrEngineProvider.appleEngine().updateLanguage()
            },
            llmRefiner: llmRefiner,
            asrEngineRegistry: asrEngineRegistry,
            textOutputSinkRegistry: textOutputSinkRegistry
        )
        menuBarController.onSherpaDownloadRequested = { [weak self] in
            self?.startSherpaDownload()
        }

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
                    if self.session.isRecordingOrStarting {
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
            self.capsuleWindow.recordingClickEnabled = active
            self.headphoneCoordinator.notifyRecordingStateChanged(active)
            self.handleRecordingStateChangedForDownloadCapsule(active: active)
            if !active {
                UpdateChecker.shared.resumeDeferredRestartPromptIfPossible()
            }
            #if DEBUG_BUILD
            MemoryProbe.log(active ? "recording-start" : "recording-stop")
            if !active {
                // 录音结束 3s 后再探一次，看 fallback / coordinator / 临时缓冲是否已释放
                // (Probe again 3s after recording ends to see whether fallback / coordinators / temporary buffers released.)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    MemoryProbe.log("recording-idle-3s")
                }
            }
            #endif
        }
        session.onRefiningStateChanged = { [weak self] refining in
            guard let self else { return }
            self.fnKeyMonitor.isRefining = refining
            if !refining {
                UpdateChecker.shared.resumeDeferredRestartPromptIfPossible()
            }
        }
        menuBarController.onTriggerKeyChanged = { [weak self] keyCode in
            self?.fnKeyMonitor.triggerKeyCode = keyCode
        }
        // ESC 取消录音，不上屏（ESC cancels recording, no text injection）
        fnKeyMonitor.onEscPressed = { [weak self] in self?.session.cancel() }
        // Return 确认结束录音，继续走自动标点和 LLM 优化（Return commits recording through normal finalization）
        fnKeyMonitor.onCommitStop = { [weak self] in self?.session.stop() }
        // Space/Backspace/标点立即上屏，跳过 LLM（Space/Backspace/punctuation injects text immediately, skipping LLM）
        fnKeyMonitor.onImmediateStop = { [weak self] punctuation in
            self?.session.stopImmediate(appending: punctuation)
        }
        // 全新安装：等 OOBE 完成再启动 tap，避免立刻弹辅助功能权限对话框
        // (Fresh install: defer event tap until OOBE finishes to avoid the early Accessibility prompt.)
        if AppSettings.hasCompletedOOBE {
            fnKeyMonitor.start()
        }

        // 耳机线控按钮协调器（默认关闭，需用户在菜单显式开启）
        // (Headphone remote-button coordinator — opt-in via menu.)
        headphoneCoordinator = HeadphoneInputCoordinator(
            session: session,
            cancelSherpaAutoUnload: { [weak self] in self?.cancelSherpaAutoUnloadTask() },
            onAccessibilityWarning: { [weak self] in self?.menuBarController.showAccessibilityWarning() }
        )
        if AppSettings.hasCompletedOOBE {
            headphoneCoordinator.startIfEnabled()
        }

        UpdateChecker.shared.shouldDeferRestartPrompt = { [weak self] in
            guard let self else { return false }
            return self.session.isRecordingOrStarting || self.session.isRefining
        }

        // 启动 5 秒后静默检查更新，不阻塞启动流程（Silently check for updates 5s after launch, non-blocking）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkForUpdates(silent: true)
        }

        #if DEBUG_BUILD
        // 内存优化基线测量：启动瞬间 / 启动 5s 后（异步初始化结束）
        // (Memory baseline: at launch / 5s after launch when async init has settled.)
        MemoryProbe.log("launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            MemoryProbe.log("idle-5s-after-launch")
        }
        #endif

        // 监听系统内存压力，仅在内存严重不足时释放模型（Monitor system memory pressure, release model only on critical shortage）
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.session.isRecording else { return }
            DebugLog.info("[AppDelegate] Critical memory pressure, releasing Sherpa model")
            self.releaseSherpaModelsIfNeeded()
        }
        memoryPressureSource?.resume()

        // 首次启动展示 OOBE 引导（Show first-launch OOBE on cold start）
        #if DEBUG_BUILD
        if let asrSettingsSnapshot = DebugASRSettingsSnapshotArguments.current {
            DispatchQueue.main.async { [weak self] in
                self?.showASRSettingsSnapshot(tabIdentifier: asrSettingsSnapshot.tabIdentifier)
            }
        } else if let snapshotStep = DebugOOBESnapshotArguments.current?.step {
            DispatchQueue.main.async { [weak self] in self?.showOOBESnapshot(step: snapshotStep) }
        } else if !AppSettings.hasCompletedOOBE {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }
        #else
        if !AppSettings.hasCompletedOOBE {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }
        #endif

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
            name: AppSettings.recognitionEngineSettingsDidChangeNotification,
            object: UserDefaults.standard
        )
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

        if session.isRecording && session.activeRecognitionSession?.requiresModelReloadOnRouteChange == true {
            pendingSherpaModelRelease = true
            return
        }

        releaseSherpaModelsIfNeeded()
    }

    private func handleSherpaSelectionChange() {
        guard asrEngineProvider.hasSherpaEngine else { return }

        if session.isRecording && session.activeRecognitionSession?.requiresModelReloadOnRouteChange == true {
            pendingSherpaModelRelease = true
            DebugLog.info("[AppDelegate] Sherpa preset changed, releasing old model after current recording")
            return
        }

        DebugLog.info("[AppDelegate] Sherpa preset changed, releasing old model")
        releaseSherpaModelsIfNeeded()
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
              asrEngineProvider.isSherpaModelLoaded else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sherpaAutoUnloadWorkItem = nil
            guard !self.session.isRecording,
                  self.selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
                  self.asrEngineProvider.isSherpaModelLoaded else { return }
            DebugLog.info("[AppDelegate] Sherpa idle timeout reached, auto-releasing local model")
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
        asrEngineProvider.releaseSherpaEngine()
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

    // MARK: - Sherpa download capsule

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

    private func requestPermissions() {
        PermissionService.shared.requestStartupPermissions()
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
            DebugLog.info("[SherpaOnnx] Launch migration: \(savedID) is not downloaded, switching to downloaded preset \(alt.id)")
        }
        // 若同语言下都没有已下载的，保留原值；下次切到 sherpa 引擎时会触发下载提示
        // (If nothing downloaded in this language, keep original; next sherpa switch will prompt download)
    }

    /// 展示 OOBE 引导窗口（Show OOBE onboarding window）
    /// 控制器生命周期统一交给 MenuWindowRouter 管理，这里只注入业务回调。
    /// (Lifetime is owned by MenuWindowRouter — this method just injects business callbacks.)
    func showOOBE() {
        menuBarController.presentOOBE { controller in
            controller.onFinish = { [weak self] engine, triggerKey in
                guard let self else { return }
                // 同步触发键到 FnKeyMonitor（Sync trigger key to FnKeyMonitor）
                self.fnKeyMonitor.triggerKeyCode = triggerKey
                // OOBE 完成后再启动 tap 与权限请求；start 是幂等的
                // (Start tap & request perms now; start() is idempotent so repeated OOBE runs are safe.)
                self.fnKeyMonitor.start()
                self.headphoneCoordinator.setEnabled(AppSettings.headphoneControlEnabled)
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
            }
        }
    }

    #if DEBUG_BUILD
    func showOOBESnapshot(step: Int) {
        menuBarController.presentOOBESnapshot(step: step) { controller in
            controller.onFinish = { _, _ in }
        }
    }

    private func showASRSettingsSnapshot(tabIdentifier: String) {
        menuBarController.presentASRSettingsSnapshot(tabIdentifier: tabIdentifier)
    }
    #endif

    /// OOBE 完成后用：触发已存在的 Sherpa 下载提示流程。
    /// (Trigger existing Sherpa download prompt after OOBE.)
    fileprivate func promptSherpaDownloadPublic() {
        promptSherpaDownload()
    }

    /// 由菜单调用：转发耳机控制开关切换给协调器。
    /// (Called by menu — forward the headphone control toggle to the coordinator.)
    func setHeadphoneControlEnabled(_ enabled: Bool) {
        headphoneCoordinator.setEnabled(enabled)
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
        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
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
        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
            startSherpaDownload()
        }
    }
}

// MARK: - RecordingSessionDelegate

extension AppDelegate: RecordingSessionDelegate {
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
