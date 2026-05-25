import Cocoa

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstance = SingleInstanceController()
    private let recordingBroadcaster = RecordingStateBroadcaster()
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
    private var sherpaDownloadCapsulePresenter: SherpaDownloadCapsulePresenter!
    private var sherpaLifecycle: SherpaLifecycleCoordinator!
    private var session: RecordingSessionController!

    public override init() { super.init() }

    deinit { sherpaLifecycle?.stop(); NotificationCenter.default.removeObserver(self) }

    public func applicationWillTerminate(_ notification: Notification) { singleInstance.releaseSingleInstance(currentPID: ProcessInfo.processInfo.processIdentifier) }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        singleInstance.claimSingleInstance(currentPID: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: Bundle.main.bundleIdentifier, currentExecutableURL: Bundle.main.executableURL?.standardizedFileURL)
        configureLaunchDefaults()
        buildDependencyGraph()
        configureMenu()
        configureInput()
        configureRecordingBroadcasting()
        configureUpdateChecker()
        configureHeadphoneCoordinator()
        startInputIfNeeded()
        schedulePostLaunchChecks()
        presentInitialWindowsIfNeeded()
        observeActiveAppChanges()
    }

    // MARK: - Launch Wiring

    private func configureLaunchDefaults() {
        MainMenuInstaller.install()
        AppSettings.registerDefaults()
        if !AppSettings.doubaoASRLowLatencyDefaultApplied {
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.doubaoASREnableNonstream)
            AppSettings.doubaoASRLowLatencyDefaultApplied = true
        }
        SherpaModelPreset.probeMirrorAsync()
        SherpaLifecycleCoordinator.migratePresetIfNeeded()
        if AppSettings.hasCompletedOOBE { requestPermissions() }
    }

    private func buildDependencyGraph() {
        llmRefiner = LLMRefiner()
        textInjector = TextInjector()
        capsuleWindow = CapsuleWindowController()
        capsuleWindow.onRecordingClick = { [weak self] in
            guard let self, self.session.isRecording else { return }; self.session.stop()
        }
        audioEngine = AudioEngineController()
        textPostProcessorRegistry = TextPostProcessorRegistry(processors: [
            SherpaPunctuationProcessor(registry: asrEngineRegistry) { [weak self] text in self?.asrEngineProvider.sherpaEngine().punctuate(text) },
            HeuristicPunctuationProcessor(),
        ])
        textOutputSinkRegistry = TextOutputSinkRegistry(sinks: [
            PasteboardInjectSink(injector: textInjector),
            // StreamingInjectSink(injector: textInjector), // AX 写入在部分 App 中仍不稳定。
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
        sherpaDownloadCapsulePresenter = SherpaDownloadCapsulePresenter(
            capsuleWindow: capsuleWindow,
            isRecording: { [weak self] in self?.session.isRecording == true }
        )
        sherpaLifecycle = SherpaLifecycleCoordinator(
            registry: asrEngineRegistry,
            provider: asrEngineProvider,
            sessionInspector: { [weak self] in self.map { SessionInspectorAdapter(controller: $0.session) } }
        )
        sherpaLifecycle.start()
    }

    private func configureMenu() {
        menuBarController = MenuBarController(
            onLanguageChanged: { [weak self] in self?.asrEngineProvider.appleEngine().updateLanguage() },
            llmRefiner: llmRefiner,
            asrEngineRegistry: asrEngineRegistry,
            textOutputSinkRegistry: textOutputSinkRegistry
        )
        menuBarController.onSherpaDownloadRequested = { [weak self] in self?.startSherpaDownload() }
        menuBarController.onTriggerKeyChanged = { [weak self] keyCode in self?.fnKeyMonitor.triggerKeyCode = keyCode }
    }

    private func configureInput() {
        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in self?.handleTriggerDown() },
            onFnUp: { [weak self] in if !AppSettings.silenceAutoStopEnabled { self?.session.stop() } }
        )
        fnKeyMonitor.triggerKeyCode = AppSettings.triggerKeyCode
        fnKeyMonitor.onTapDisabled = { [weak self] in self?.menuBarController.showAccessibilityWarning() }
        fnKeyMonitor.onEscPressed = { [weak self] in self?.session.cancel() }
        fnKeyMonitor.onCommitStop = { [weak self] in self?.session.stop() }
        fnKeyMonitor.onImmediateStop = { [weak self] punctuation in self?.session.stopImmediate(appending: punctuation) }
    }

    private func configureRecordingBroadcasting() {
        recordingBroadcaster.addRecordingObserver { [weak fnKeyMonitor] active in fnKeyMonitor?.isRecording = active }
        recordingBroadcaster.addRecordingObserver { [weak capsuleWindow] active in capsuleWindow?.recordingClickEnabled = active }
        recordingBroadcaster.addRecordingObserver { [weak self] active in self?.headphoneCoordinator.notifyRecordingStateChanged(active) }
        recordingBroadcaster.addRecordingObserver { [weak sherpaDownloadCapsulePresenter] active in sherpaDownloadCapsulePresenter?.handleRecordingStateChanged(active: active) }
        recordingBroadcaster.addRecordingObserver { active in if !active { UpdateChecker.shared.resumeDeferredRestartPromptIfPossible() } }
        #if DEBUG_BUILD
        recordingBroadcaster.addRecordingObserver { active in
            MemoryProbe.log(active ? "recording-start" : "recording-stop")
            if !active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { MemoryProbe.log("recording-idle-3s") }
            }
        }
        #endif
        recordingBroadcaster.addRefiningObserver { [weak fnKeyMonitor] refining in fnKeyMonitor?.isRefining = refining }
        recordingBroadcaster.addRefiningObserver { refining in if !refining { UpdateChecker.shared.resumeDeferredRestartPromptIfPossible() } }
        session.onRecordingStateChanged = { [weak recordingBroadcaster] active in recordingBroadcaster?.broadcastRecordingStateChanged(active) }
        session.onRefiningStateChanged = { [weak recordingBroadcaster] refining in recordingBroadcaster?.broadcastRefiningStateChanged(refining) }
    }

    private func configureUpdateChecker() {
        UpdateChecker.shared.shouldDeferRestartPrompt = { [weak self] in
            self.map { $0.session.isRecordingOrStarting || $0.session.isRefining } ?? false
        }
    }

    private func configureHeadphoneCoordinator() {
        headphoneCoordinator = HeadphoneInputCoordinator(
            session: session,
            cancelSherpaAutoUnload: { [weak self] in self?.sherpaLifecycle.cancelAutoUnload() },
            onAccessibilityWarning: { [weak self] in self?.menuBarController.showAccessibilityWarning() }
        )
    }

    private func startInputIfNeeded() {
        guard AppSettings.hasCompletedOOBE else { return }
        fnKeyMonitor.start()
        headphoneCoordinator.startIfEnabled()
    }

    private func schedulePostLaunchChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { UpdateChecker.shared.checkForUpdates(silent: true) }
        #if DEBUG_BUILD
        MemoryProbe.log("launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { MemoryProbe.log("idle-5s-after-launch") }
        #endif
    }

    private func presentInitialWindowsIfNeeded() {
        #if DEBUG_BUILD
        if let snapshot = DebugASRSettingsSnapshotArguments.current {
            DispatchQueue.main.async { [weak self] in self?.showASRSettingsSnapshot(tabIdentifier: snapshot.tabIdentifier) }
        } else if let step = DebugOOBESnapshotArguments.current?.step {
            DispatchQueue.main.async { [weak self] in self?.showOOBESnapshot(step: step) }
        } else if !AppSettings.hasCompletedOOBE {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }
        #else
        if !AppSettings.hasCompletedOOBE {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }
        #endif
    }

    private func observeActiveAppChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func handleTriggerDown() {
        if session.isShowingError {
            session.dismissError()
            return
        }
        if AppSettings.silenceAutoStopEnabled && session.isRecordingOrStarting {
            session.stop()
            return
        }
        sherpaLifecycle.cancelAutoUnload()
        session.start()
    }

    // MARK: - Workspace Events

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard session.isRecording else { return }
        if !AppSettings.silenceAutoStopEnabled { session.cancel() }
    }

    // MARK: - External API

    static func showSherpaDownloadCapsule(_ message: String) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }; appDelegate.sherpaDownloadCapsulePresenter.updateProgress(message: message, force: false)
    }

    static func finishSherpaDownloadCapsule(success: Bool, error: String?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }; appDelegate.sherpaDownloadCapsulePresenter.finishDownload(success: success, error: error)
    }

    func showOOBE() {
        menuBarController.presentOOBE { controller in
            controller.onFinish = { [weak self] engine, triggerKey in
                guard let self else { return }
                self.fnKeyMonitor.triggerKeyCode = triggerKey
                self.fnKeyMonitor.start()
                self.headphoneCoordinator.setEnabled(AppSettings.headphoneControlEnabled)
                self.requestPermissions()
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

    func setHeadphoneControlEnabled(_ enabled: Bool) { headphoneCoordinator.setEnabled(enabled) }

    #if DEBUG_BUILD
    func showOOBESnapshot(step: Int) { menuBarController.presentOOBESnapshot(step: step) { $0.onFinish = { _, _ in } } }

    private func showASRSettingsSnapshot(tabIdentifier: String) { menuBarController.presentASRSettingsSnapshot(tabIdentifier: tabIdentifier) }
    #endif

    // MARK: - Sherpa Download

    fileprivate func promptSherpaDownloadPublic() { promptSherpaDownload() }

    private func startSherpaDownload() {
        if SherpaModelDownloader.isReady() { return }
        let downloader = SherpaModelDownloader.shared
        AppDelegate.showSherpaDownloadCapsule(loc("sherpa.downloading.start"))
        downloader.addObserver(
            progress: { [weak self] _, _, _, message in if self != nil { AppDelegate.showSherpaDownloadCapsule(message) } },
            complete: { [weak self] success, error in if self != nil { AppDelegate.finishSherpaDownloadCapsule(success: success, error: error) } }
        )
        _ = downloader.startDownload()
    }

    private func promptSherpaDownload() { showSherpaDownloadPrompt(message: loc("sherpa.download.message")) }

    private func promptSherpaReDownload() { showSherpaDownloadPrompt(message: loc("sherpa.redownload.message")) }

    private func showSherpaDownloadPrompt(message: String) {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.download.title")
        alert.informativeText = message
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("sherpa.download.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))
        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
            startSherpaDownload()
        }
    }

    private func requestPermissions() { PermissionService.shared.requestStartupPermissions() }
}

// MARK: - RecordingSessionDelegate

extension AppDelegate: RecordingSessionDelegate {
    func sessionRequiresSherpaModelDownload(redownload: Bool) {
        if redownload { promptSherpaReDownload() } else { promptSherpaDownload() }
    }

    func sessionDidEnd() { sherpaLifecycle.performPostRecordingCleanup() }
}
