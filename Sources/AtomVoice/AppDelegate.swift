import Cocoa
import AVFoundation
import Speech
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var fnKeyMonitor: FnKeyMonitor!
    private var audioEngine: AudioEngineController!
    private var speechRecognizer: SpeechRecognizerController!
    private var sherpaRecognizer: SherpaOnnxRecognizerController!
    private var volcengineProvider: VolcengineASRProvider!
    private var cloudRecognizer: CloudASRRecognizerController!
    private var capsuleWindow: CapsuleWindowController!
    private var textInjector: TextInjector!
    private var llmRefiner: LLMRefiner!
    private var volumeController: VolumeController!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var oobeWindowController: OOBEWindowController?
    private var isRecording = false
    private var currentRecordingEngine = "apple"
    private var liveInsertionActive = false
    private var liveInsertionCommittedText = ""
    private var liveInsertionLatestText = ""
    private var liveInsertionPasteInFlight = false
    private var recordingGeneration = 0
    private var doubaoWaitingForFirstResult = false
    private let doubaoFallbackAudioQueue = DispatchQueue(label: "com.atomvoice.doubaoFallbackAudio")
    private var doubaoFallbackAudioBuffers: [AVAudioPCMBuffer] = []
    private var doubaoFallbackErrorMessage: String?
    private var doubaoFallbackAppleLiveActive = false
    private var doubaoFallbackPrefixText = ""
    // Sherpa 模型预加载期间的音频缓冲，复用 doubao fallback 的模式（Audio buffer during Sherpa model preloading, reusing doubao fallback pattern）
    private var sherpaPreloadActive = false
    private let sherpaPreloadQueue = DispatchQueue(label: "com.atomvoice.sherpaPreload")
    private var sherpaPreloadBuffers: [AVAudioPCMBuffer] = []

    deinit {
        memoryPressureSource?.cancel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherRunningInstances()

        UserDefaults.standard.register(defaults: [
            "selectedLanguage": "zh-CN",
            "recognitionEngine": "apple",
            "appleLiveInsertionEnabled": false,
            "llmEnabled": false,
            "llmAPIBaseURL": "https://api.openai.com/v1",
            "llmModel": "gpt-4o-mini",
            "autoPunctuationEnabled": true,
            "appleOnDeviceRecognitionEnabled": false,
            "llmResultDelay": 0.3,
            "animationStyle": "dynamicIsland",
            "animationSpeed": "medium",
            "silenceAutoStopEnabled": false,
            "silenceDuration": 2.0,
            "silenceThreshold": -40.0,
            "steadyNoiseSensitivity": 1,  // 0=低, 1=中, 2=高 (0=low, 1=medium, 2=high)
            "triggerKeyCode": 63,
            "lowerVolumeOnRecording": false,
            "sherpaModelsReady": false,
            "doubaoASREndpoint": VolcengineASRSettings.defaultEndpoint,
            "doubaoASRResourceID": VolcengineASRSettings.defaultResourceID,
            "doubaoASREnableITN": true,
            "doubaoASREnableDDC": false,
            "doubaoASREnableNonstream": false,
            "doubaoASRPrivacyAccepted": false,
            OOBEWindowController.completionDefaultsKey: false,
        ])
        if !UserDefaults.standard.bool(forKey: "doubaoASRLowLatencyDefaultApplied") {
            UserDefaults.standard.set(false, forKey: "doubaoASREnableNonstream")
            UserDefaults.standard.set(true, forKey: "doubaoASRLowLatencyDefaultApplied")
        }
        selfHealSherpaModelsReadyIfNeeded()

        requestPermissions()

        llmRefiner = LLMRefiner()
        textInjector = TextInjector()
        capsuleWindow = CapsuleWindowController()
        audioEngine = AudioEngineController()
        speechRecognizer = SpeechRecognizerController()
        sherpaRecognizer = SherpaOnnxRecognizerController()
        volcengineProvider = VolcengineASRProvider()
        cloudRecognizer = CloudASRRecognizerController(provider: volcengineProvider)
        volumeController = VolumeController()

        menuBarController = MenuBarController(
            onLanguageChanged: { [weak self] in
                self?.speechRecognizer.updateLanguage()
            },
            llmRefiner: llmRefiner
        )
        menuBarController.onSherpaDownloadRequested = { [weak self] in
            self?.startSherpaDownload()
        }

        audioEngine.onSilenceTimeout = { [weak self] in self?.stopRecording() }

        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in
                guard let self else { return }
                let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
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
                let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
                // 静音模式下松开 Fn 不停止录音（In silence mode, releasing Fn does not stop recording）
                if !silenceMode {
                    self.stopRecording()
                }
            }
        )
        fnKeyMonitor.triggerKeyCode = UInt16(UserDefaults.standard.integer(forKey: "triggerKeyCode"))
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
            print("[AppDelegate] 系统内存压力，释放 Sherpa 模型")
            self.sherpaRecognizer.releaseModels()
        }
        memoryPressureSource?.resume()

        // 首次启动展示 OOBE 引导（Show first-launch OOBE on cold start）
        if !UserDefaults.standard.bool(forKey: OOBEWindowController.completionDefaultsKey) {
            DispatchQueue.main.async { [weak self] in self?.showOOBE() }
        }

        // 监听前台应用切换：录音期间切换程序则取消录音（Monitor active app change: cancel recording when switching apps）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
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
            print("[AppDelegate] 正在退出旧实例 pid=\(app.processIdentifier)")
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            otherApps.filter { !$0.isTerminated }.forEach { app in
                print("[AppDelegate] 旧实例未正常退出，强制结束 pid=\(app.processIdentifier)")
                app.forceTerminate()
            }
        }
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard isRecording else { return }
        // 静音模式（单击说话）下，切换窗口是正常流程，不取消录音（In silence mode (tap-to-talk), switching windows is normal flow, don't cancel recording）
        let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        if silenceMode { return }
        // 长按模式下切换了前台应用，取消本次录音（In hold-to-talk mode, switched frontmost app, cancel this recording）
        cancelRecording()
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

        guard !AudioEngineController.availableInputDevices().isEmpty else {
            DispatchQueue.main.async { [self] in
                capsuleWindow.show()
                capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
            }
            return
        }

        // Sherpa 引擎：优先读缓存标记，只有标记为 false 时才做一次自愈检查（Sherpa engine: prioritize cached flag; only run self-heal check when flag is false）
        let engine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
        if engine == "sherpaOnnx" {
            if !UserDefaults.standard.bool(forKey: "sherpaModelsReady") {
                if !selfHealSherpaModelsReadyIfNeeded() {
                    if SherpaModelDownloader.shared.isDownloading { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.promptSherpaDownload()
                    }
                    return
                }
            }
        }
        if engine == VolcengineASRSettings.engineCode {
            guard UserDefaults.standard.bool(forKey: "doubaoASRPrivacyAccepted") else {
                DispatchQueue.main.async { [self] in
                    capsuleWindow.show()
                    capsuleWindow.showError(loc("doubao.error.privacyNotAccepted"), dismissAfter: 5)
                }
                return
            }
            if let error = VolcengineASRSettings.load().validationError {
                DispatchQueue.main.async { [self] in
                    capsuleWindow.show()
                    capsuleWindow.showError(error, dismissAfter: 5)
                }
                return
            }
        }
        
        // 取消正在进行的 LLM 处理，如果有（Cancel any ongoing LLM processing, if any）
        llmRefiner.cancel()
        doubaoFallbackErrorMessage = nil
        doubaoFallbackAppleLiveActive = false
        doubaoFallbackPrefixText = ""
        clearDoubaoFallbackAudioBuffers()
        
        isRecording = true
        fnKeyMonitor.isRecording = true
        recordingGeneration += 1
        let generation = recordingGeneration
        currentRecordingEngine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
        liveInsertionActive = currentRecordingEngine == "apple" &&
            UserDefaults.standard.bool(forKey: "appleLiveInsertionEnabled") &&
            !UserDefaults.standard.bool(forKey: "llmEnabled")
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false

        let lowerVolume = UserDefaults.standard.bool(forKey: "lowerVolumeOnRecording")
        os_log(.error, "[AppDelegate] startRecording: lowerVolume=%d, vc=%@", lowerVolume, volumeController != nil ? "yes" : "nil")
        if lowerVolume {
            volumeController.saveAndDecreaseVolume()
        }

        DispatchQueue.main.async { [self] in
            guard isRecording, recordingGeneration == generation else { return }

            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                startDoubaoRecording(generation: generation)
            } else if currentRecordingEngine == "sherpaOnnx" {
                capsuleWindow.show()
                if sherpaRecognizer.isModelLoaded {
                    // 模型已缓存，直接开始录音，不显示加载动画（Model cached, start recording directly without loading animation）
                    startSherpaRecordingAfterModelLoad()
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

        capsuleWindow.show()
        let request = speechRecognizer.start(
            onResult: { [weak self] text, isFinal in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.capsuleWindow.updateText(text)
                    self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
                }
            },
            onRequestSwitch: { [weak self] newRequest in
                self?.audioEngine.switchRequest(newRequest)
            }
        )

        if !audioEngine.start(
            bandsHandler: { [weak self] bands in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateBands(bands)
                }
            },
            recognitionRequest: request
        ) {
            _ = speechRecognizer.stop()
            handleAudioStartFailure()
        }
    }

    private func startSherpaRecordingAfterModelLoad() {
        if let error = sherpaRecognizer.start(onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                self?.capsuleWindow.updateText(text)
            }
        }) {
            isRecording = false
            fnKeyMonitor.isRecording = false
            volumeController.restoreVolume()
            print("[SherpaOnnx] 模型加载失败: \(error)")

            // 文件缺失或模型无法创建时，重置标记并提示重新下载（When files are missing or model cannot be created, reset flag and prompt re-download）
            if sherpaRecognizer.lastStartFailureKind == .missingRuntime ||
                sherpaRecognizer.lastStartFailureKind == .missingModel ||
                sherpaRecognizer.lastStartFailureKind == .invalidModel {
                UserDefaults.standard.set(false, forKey: "sherpaModelsReady")
                SherpaModelDownloader.printMissingRequiredFiles()
                capsuleWindow.showError(error, dismissAfter: 3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    self?.promptSherpaReDownload()
                }
            } else {
                // 文件存在但加载失败（dylib 问题等），只报错不重置标记（Files exist but load failed (e.g. dylib issue), only show error without resetting flag）
                capsuleWindow.showError(error, dismissAfter: 6)
            }
            return
        }

        capsuleWindow.showRecording()
        if !audioEngine.start(
            bandsHandler: { [weak self] bands in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateBands(bands)
                }
            },
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                self?.sherpaRecognizer.accept(buffer: buffer)
            }
        ) {
            _ = sherpaRecognizer.stop()
            handleAudioStartFailure()
        }
    }

    /// Sherpa 模型未加载时：立即启动录音缓存音频，后台加载模型，加载完成后喂入全部缓存并无缝切换（When Sherpa model is not loaded: start recording immediately and buffer audio, load model in background, feed all buffered audio and switch seamlessly after load）
    private func startSherpaRecordingWithDeferredModel(generation: Int) {
        sherpaPreloadActive = true
        clearSherpaPreloadBuffers()

        capsuleWindow.showProgress(loc("sherpa.loadingModel"))

        // 1. 立即启动 AudioEngine，缓存音频（Start AudioEngine immediately, buffer audio）
        if !audioEngine.start(
            bandsHandler: { [weak self] bands in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateBands(bands)
                }
            },
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                guard let self else { return }
                if self.sherpaPreloadActive {
                    self.appendSherpaPreloadBuffer(buffer)
                } else {
                    self.sherpaRecognizer.accept(buffer: buffer)
                }
            }
        ) {
            sherpaPreloadActive = false
            clearSherpaPreloadBuffers()
            handleAudioStartFailure()
            return
        }

        // 2. 后台加载模型（Load model in background）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = self.sherpaRecognizer.start(onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateText(text)
                }
            })

            // 3. 回主线程处理结果（Return to main thread to handle result）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isRecording, self.recordingGeneration == generation,
                      self.currentRecordingEngine == "sherpaOnnx" else {
                    self.sherpaPreloadActive = false
                    self.clearSherpaPreloadBuffers()
                    return
                }

                if let error {
                    // 模型加载失败，停止录音（Model load failed, stop recording）
                    self.sherpaPreloadActive = false
                    self.clearSherpaPreloadBuffers()
                    self.audioEngine.stop()
                    self.isRecording = false
                    self.fnKeyMonitor.isRecording = false
                    self.volumeController.restoreVolume()
                    print("[SherpaOnnx] 模型加载失败: \(error)")

                    if self.sherpaRecognizer.lastStartFailureKind == .missingRuntime ||
                        self.sherpaRecognizer.lastStartFailureKind == .missingModel ||
                        self.sherpaRecognizer.lastStartFailureKind == .invalidModel {
                        UserDefaults.standard.set(false, forKey: "sherpaModelsReady")
                        SherpaModelDownloader.printMissingRequiredFiles()
                        self.capsuleWindow.showError(error, dismissAfter: 3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            self?.promptSherpaReDownload()
                        }
                    } else {
                        self.capsuleWindow.showError(error, dismissAfter: 6)
                    }
                    return
                }

                // 4. 模型加载成功，在 preloadQueue 上排空缓存后切换到直推模式（Model loaded, drain buffer on preloadQueue then switch to live mode）
                self.sherpaPreloadQueue.async { [weak self] in
                    guard let self else { return }
                    let buffered = self.sherpaPreloadBuffers
                    self.sherpaPreloadBuffers = []
                    self.sherpaPreloadActive = false

                    // 按顺序喂入全部缓存音频（Feed all buffered audio in order）
                    for buf in buffered {
                        self.sherpaRecognizer.accept(buffer: buf)
                    }

                    // 二次排空：处理 flag 切换期间积压的零星缓冲（Second drain for stragglers during flag transition）
                    self.sherpaPreloadQueue.async { [weak self] in
                        guard let self else { return }
                        let stragglers = self.sherpaPreloadBuffers
                        self.sherpaPreloadBuffers = []
                        for buf in stragglers {
                            self.sherpaRecognizer.accept(buffer: buf)
                        }

                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isRecording, self.recordingGeneration == generation else { return }
                            self.capsuleWindow.stopShimmer()
                            self.capsuleWindow.showRecording()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sherpa 预加载音频缓冲（复用 copyAudioBuffer）

    private func appendSherpaPreloadBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyAudioBuffer(buffer) else { return }
        sherpaPreloadQueue.async { [weak self] in
            self?.sherpaPreloadBuffers.append(copy)
        }
    }

    private func clearSherpaPreloadBuffers() {
        sherpaPreloadQueue.sync {
            sherpaPreloadBuffers.removeAll(keepingCapacity: false)
        }
    }

    private func startDoubaoRecording(generation: Int) {
        guard isRecording, recordingGeneration == generation else { return }
        DebugLog.info("[AppDelegate] 启动豆包录音, generation=\(generation)")
        doubaoWaitingForFirstResult = true
        capsuleWindow.show()
        capsuleWindow.showRecording()
        // 延迟一帧挂扫光，表示正在连接（Delay one frame to apply shimmer, indicating connecting）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingGeneration == generation, self.isRecording else { return }
            self.capsuleWindow.applyShimmerToCapsule()
        }
        if let error = cloudRecognizer.start(onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.doubaoFallbackPrefixText = text
                if self.doubaoWaitingForFirstResult {
                    self.doubaoWaitingForFirstResult = false
                    // 收到第一条结果，停掉连接扫光并丢弃 fallback 缓冲（Stop connecting shimmer and discard fallback buffers on first result）
                    self.capsuleWindow.stopShimmer()
                    self.clearDoubaoFallbackAudioBuffers()
                }
                self.capsuleWindow.updateText(text)
            }
        }, onError: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.handleDoubaoRecognitionError(message)
            }
        }) {
            doubaoWaitingForFirstResult = false
            currentRecordingEngine = "apple"
            print("[Doubao] 启动失败，回退到 Apple Speech: \(error)")
            startAppleRecording(generation: generation)
            capsuleWindow.updateText(loc("menu.recognitionEngine.apple"))
            return
        }

        if !audioEngine.start(
            bandsHandler: { [weak self] bands in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateBands(bands)
                }
            },
            recognitionRequest: nil,
            audioBufferHandler: { [weak self] buffer, _ in
                self?.appendDoubaoFallbackAudioBuffer(buffer)
                self?.cloudRecognizer.accept(buffer: buffer)
            }
        ) {
            cloudRecognizer.cancel()
            handleAudioStartFailure()
        }
    }

    private func handleDoubaoRecognitionError(_ message: String) {
        guard currentRecordingEngine == VolcengineASRSettings.engineCode else { return }
        guard doubaoFallbackErrorMessage == nil else { return }

        DebugLog.error("[AppDelegate] 豆包识别错误: \(message), isRecording=\(isRecording)")

        doubaoFallbackErrorMessage = message
        if doubaoFallbackPrefixText.isEmpty {
            doubaoFallbackPrefixText = cloudRecognizer.currentText
        }
        cloudRecognizer.cancel()
        liveInsertionActive = false
        doubaoWaitingForFirstResult = false
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false

        if isRecording {
            startAppleLiveFallbackAfterDoubaoError(generation: recordingGeneration)
            print("[Doubao] 识别失败，录音结束后将回退到 Apple Speech: \(message)")
        } else {
            capsuleWindow.showError(loc("doubao.fallback.withError", message), dismissAfter: 5)
        }
    }

    private func startAppleLiveFallbackAfterDoubaoError(generation: Int) {
        guard isRecording,
              recordingGeneration == generation,
              currentRecordingEngine == VolcengineASRSettings.engineCode,
              !doubaoFallbackAppleLiveActive
        else { return }

        DebugLog.info("[AppDelegate] 启动 Apple 实时回退 (豆包错误后)")

        doubaoFallbackAppleLiveActive = true
        capsuleWindow.stopShimmer()
        let errorHint = doubaoFallbackErrorMessage ?? ""
        let fallbackText = errorHint.isEmpty
            ? loc("menu.recognitionEngine.apple")
            : loc("doubao.fallback.withError", errorHint)
        capsuleWindow.updateText(fallbackText)

        let request = speechRecognizer.start(
            onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    guard let self,
                          self.recordingGeneration == generation,
                          self.doubaoFallbackAppleLiveActive
                    else { return }
                    self.capsuleWindow.updateText(text)
                }
            },
            onRequestSwitch: { [weak self] newRequest in
                self?.audioEngine.switchRequest(newRequest)
            }
        )

        if let request {
            audioEngine.switchRequest(request)
        }
    }

    private func handleAudioStartFailure() {
        isRecording = false
        fnKeyMonitor.isRecording = false
        volumeController.restoreVolume()
        doubaoFallbackErrorMessage = nil
        doubaoFallbackAppleLiveActive = false
        doubaoFallbackPrefixText = ""
        clearDoubaoFallbackAudioBuffers()
        liveInsertionActive = false
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false
        capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
    }

    private func appendDoubaoFallbackAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // 豆包已成功返回过数据后不再缓存 fallback 音频（Stop caching fallback audio once Doubao has returned data successfully）
        guard doubaoWaitingForFirstResult else { return }
        guard let copiedBuffer = copyAudioBuffer(buffer) else { return }
        doubaoFallbackAudioQueue.async { [weak self] in
            self?.doubaoFallbackAudioBuffers.append(copiedBuffer)
        }
    }

    private func snapshotDoubaoFallbackAudioBuffers() -> [AVAudioPCMBuffer] {
        doubaoFallbackAudioQueue.sync { doubaoFallbackAudioBuffers }
    }

    private func clearDoubaoFallbackAudioBuffers() {
        doubaoFallbackAudioQueue.sync {
            doubaoFallbackAudioBuffers.removeAll(keepingCapacity: false)
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

    private func stopRecording() {
        guard isRecording else { return }
        let generation = recordingGeneration
        isRecording = false
        fnKeyMonitor.isRecording = false

        volumeController.restoreVolume()

        DispatchQueue.main.async { [self] in
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                doubaoWaitingForFirstResult = false
                audioEngine.stop()
                if let fallbackError = doubaoFallbackErrorMessage {
                    cloudRecognizer.cancel()
                    finishDoubaoRecordingWithAppleFallback(generation: generation, originalError: fallbackError)
                    return
                }
                cloudRecognizer.stop { [weak self] recognizedText, errorMsg in
                    guard let self, self.recordingGeneration == generation else { return }
                    if let errorMsg {
                        self.finishDoubaoRecordingWithAppleFallback(
                            generation: generation,
                            originalError: errorMsg,
                            fallbackTextIfAppleEmpty: recognizedText
                        )
                } else {
                    self.clearDoubaoFallbackAudioBuffers()
                    self.doubaoFallbackErrorMessage = nil
                    self.doubaoFallbackAppleLiveActive = false
                    self.doubaoFallbackPrefixText = ""
                    self.finishRecording(with: recognizedText)
                }
                }
                return
            }

            let recognizedText = currentRecordingEngine == "sherpaOnnx" ? sherpaRecognizer.stop() : speechRecognizer.stop()
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
        let buffers = snapshotDoubaoFallbackAudioBuffers()
        doubaoFallbackErrorMessage = nil
        let cloudPrefixText = fallbackTextIfAppleEmpty.isEmpty ? doubaoFallbackPrefixText : fallbackTextIfAppleEmpty
        doubaoFallbackPrefixText = ""
        let shouldStopAppleLiveFallback = doubaoFallbackAppleLiveActive
        doubaoFallbackAppleLiveActive = false
        let liveFallbackText = shouldStopAppleLiveFallback ? speechRecognizer.stop() : ""

        guard !buffers.isEmpty else {
            clearDoubaoFallbackAudioBuffers()
            currentRecordingEngine = "apple"
            let text = combinedFallbackText(prefix: cloudPrefixText, cachedText: "", liveText: liveFallbackText)
            if punctuation != nil {
                finishImmediateRecording(with: text, appending: punctuation, errorMsg: text.isEmpty ? originalError : nil)
            } else {
                finishRecording(with: text, errorMsg: text.isEmpty ? originalError : nil)
            }
            return
        }

        currentRecordingEngine = "apple"
        capsuleWindow.showProgress(loc("menu.recognitionEngine.apple"))
        speechRecognizer.recognize(buffers: buffers, onResult: { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.capsuleWindow.updateText(self.combinedFallbackText(prefix: cloudPrefixText, cachedText: text, liveText: liveFallbackText))
            }
        }) { [weak self] appleText in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.clearDoubaoFallbackAudioBuffers()
                let recognizedText = self.combinedFallbackText(prefix: cloudPrefixText, cachedText: appleText, liveText: liveFallbackText)
                let errorMsg = recognizedText.isEmpty ? originalError : nil

                if punctuation != nil {
                    self.finishImmediateRecording(with: recognizedText, appending: punctuation, errorMsg: errorMsg)
                } else {
                    self.finishRecording(with: recognizedText, errorMsg: errorMsg)
                }
            }
        }
    }

    private func combinedFallbackText(prefix: String, cachedText: String, liveText: String) -> String {
        var result = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        result = appendFallbackSegment(cachedText, to: result)
        result = appendFallbackSegment(liveText, to: result)
        return result
    }

    private func appendFallbackSegment(_ segment: String, to base: String) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return base }
        guard !base.isEmpty else { return segment }

        if segment.hasPrefix(base) { return segment }
        if base.hasSuffix(segment) { return base }

        let maxOverlap = min(base.count, segment.count)
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if base.suffix(length) == segment.prefix(length) {
                return base + segment.dropFirst(length)
            }
        }

        let separator = shouldInsertSpaceBetweenFallbackSegments(base, segment) ? " " : ""
        return base + separator + segment
    }

    private func shouldInsertSpaceBetweenFallbackSegments(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if PunctuationProcessor.isSentenceEndingPunctuation(last) { return true }
        return last.isASCII && first.isASCII && last.isLetter && first.isLetter
    }

    private func finishRecording(with recognizedText: String, errorMsg: String? = nil) {
        let rawText = remainingTextAfterLiveInsertion(recognizedText)

        if rawText.isEmpty {
            if let errorMsg {
                capsuleWindow.showError(errorMsg, dismissAfter: 5)
            } else {
                capsuleWindow.dismiss()
            }
            return
        }

        let processedText = applyAutoPunctuation(to: rawText)
        if processedText != rawText {
            capsuleWindow.updateText(processedText)
        }

        let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled") && liveInsertionCommittedText.isEmpty
        let apiKey = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""

        if llmEnabled && !apiKey.isEmpty {
            capsuleWindow.showRefining()
            llmRefiner.refine(text: processedText, onProgress: { [weak self] partial in
                self?.capsuleWindow.updateText(partial)
            }) { [weak self] refined, errorMsg in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let errorMsg {
                        // 立即注入文字，同时胶囊显示错误 3 秒（Inject text immediately, while capsule shows error for 3 seconds）
                        self.textInjector.inject(text: processedText)
                        self.capsuleWindow.showError(errorMsg)
                        return
                    }
                    let finalText = refined ?? processedText
                    self.capsuleWindow.updateText(finalText)
                    let delay = UserDefaults.standard.double(forKey: "llmResultDelay")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.capsuleWindow.dismiss {
                            self.textInjector.inject(text: finalText)
                        }
                    }
                }
            }
        } else {
            capsuleWindow.dismiss { [self] in
                textInjector.inject(text: processedText)
            }
        }
    }

    private func commitAppleLiveSegmentIfNeeded(from text: String, isFinal: Bool) {
        guard liveInsertionActive, isRecording, currentRecordingEngine == "apple" else { return }
        liveInsertionLatestText = text
        guard !liveInsertionPasteInFlight else { return }
        guard text.hasPrefix(liveInsertionCommittedText) else { return }

        let uncommitted = String(text.dropFirst(liveInsertionCommittedText.count))
        guard let endIndex = committableLiveSegmentEnd(in: uncommitted, isFinal: isFinal) else { return }

        let segment = String(uncommitted[..<endIndex])
        guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        liveInsertionCommittedText += segment
        liveInsertionPasteInFlight = true
        textInjector.inject(text: segment) { [weak self] in
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
            print("[LiveInsertion] 最终文本与已上屏前缀不完全一致，从共同前缀后继续注入")
            return String(text[commonPrefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("[LiveInsertion] 最终文本与已上屏前缀不一致，注入完整最终文本以避免丢字")
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

    private func applyAutoPunctuation(to rawText: String) -> String {
        guard UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") else { return rawText }

        if currentRecordingEngine == "sherpaOnnx",
           let punctuated = sherpaRecognizer.punctuate(rawText) {
            return punctuated
        }

        if currentRecordingEngine == VolcengineASRSettings.engineCode,
           UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") {
            return rawText
        }

        let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        return PunctuationProcessor.process(rawText, language: lang)
    }

    private func removingTrailingSentencePunctuation(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            result.removeLast()
        }
        return result
    }

    // MARK: - Sherpa 模型下载

    @discardableResult
    private func selfHealSherpaModelsReadyIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: "sherpaModelsReady") { return true }

        if SherpaModelDownloader.allModelsReady || SherpaModelDownloader.repairExtractedFilesIfNeeded() {
            UserDefaults.standard.set(true, forKey: "sherpaModelsReady")
            print("[SherpaOnnx] 已检测到完整模型，自动修复 sherpaModelsReady = true")
            return true
        }

        return false
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
                case "sherpaOnnx":
                    if !self.sherpaModelsReadyOrSelfHealed() {
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

    fileprivate func sherpaModelsReadyOrSelfHealed() -> Bool {
        if UserDefaults.standard.bool(forKey: "sherpaModelsReady") { return true }
        return selfHealSherpaModelsReadyIfNeeded()
    }

    private func startSherpaDownload() {
        guard !SherpaModelDownloader.shared.isDownloading else { return }
        if UserDefaults.standard.bool(forKey: "sherpaModelsReady") { return }
        if selfHealSherpaModelsReadyIfNeeded() { return }

        let downloader = SherpaModelDownloader.shared

        // 显示胶囊，不显示波形（Show capsule without waveform）
        capsuleWindow.show(showRecordingTimer: false)
        capsuleWindow.showProgress(loc("sherpa.downloading.start"))

        downloader.onProgress = { [weak self] current, total, _, message in
            self?.capsuleWindow.updateText(message)
        }

        downloader.onComplete = { [weak self] success, error in
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
        isRecording = false
        fnKeyMonitor.isRecording = false

        volumeController.restoreVolume()

        DispatchQueue.main.async { [self] in
            llmRefiner.cancel()
            doubaoWaitingForFirstResult = false
            doubaoFallbackErrorMessage = nil
            let shouldStopAppleLiveFallback = doubaoFallbackAppleLiveActive
            doubaoFallbackAppleLiveActive = false
            doubaoFallbackPrefixText = ""
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                cloudRecognizer.cancel()
                if shouldStopAppleLiveFallback {
                    _ = speechRecognizer.stop()
                }
            } else if currentRecordingEngine == "sherpaOnnx" {
                _ = sherpaRecognizer.stop()
            } else {
                _ = speechRecognizer.stop()
            }
            audioEngine.stop()
            clearDoubaoFallbackAudioBuffers()
            sherpaPreloadActive = false
            clearSherpaPreloadBuffers()
            liveInsertionActive = false
            liveInsertionCommittedText = ""
            liveInsertionLatestText = ""
            liveInsertionPasteInFlight = false
            capsuleWindow.dismiss()
        }
    }

    /// Space/Backspace/标点立即上屏：停止录音，跳过 LLM，直接注入（Space/Backspace/punctuation injects immediately: stop recording, skip LLM, inject directly）
    private func stopRecordingImmediate(appending punctuation: String? = nil) {
        guard isRecording else { return }
        let generation = recordingGeneration
        isRecording = false
        fnKeyMonitor.isRecording = false

        volumeController.restoreVolume()

        DispatchQueue.main.async { [self] in
            let recognizedText: String
            doubaoWaitingForFirstResult = false
            if currentRecordingEngine == VolcengineASRSettings.engineCode {
                audioEngine.stop()
                if let fallbackError = doubaoFallbackErrorMessage {
                    cloudRecognizer.cancel()
                    finishDoubaoRecordingWithAppleFallback(
                        generation: generation,
                        originalError: fallbackError,
                        appendingImmediatePunctuation: punctuation
                    )
                    return
                }
                recognizedText = cloudRecognizer.currentText
                cloudRecognizer.cancel()
            } else {
                recognizedText = currentRecordingEngine == "sherpaOnnx" ? sherpaRecognizer.stop() : speechRecognizer.stop()
                audioEngine.stop()
            }
            clearDoubaoFallbackAudioBuffers()
            doubaoFallbackErrorMessage = nil
            doubaoFallbackAppleLiveActive = false
            doubaoFallbackPrefixText = ""
            finishImmediateRecording(with: recognizedText, appending: punctuation)
        }
    }

    private func finishImmediateRecording(with recognizedText: String, appending punctuation: String?, errorMsg: String? = nil) {
        let rawText = remainingTextAfterLiveInsertion(recognizedText)

        if rawText.isEmpty {
            if let errorMsg, punctuation?.isEmpty ?? true {
                capsuleWindow.showError(errorMsg, dismissAfter: 5)
                return
            }

            capsuleWindow.dismiss { [self] in
                if let punctuation, !punctuation.isEmpty {
                    textInjector.inject(text: punctuation)
                }
            }
            return
        }

        // 本地自动标点（保留），但跳过 LLM（Local auto-punctuation applied, but skip LLM）
        let processedText = applyAutoPunctuation(to: rawText)
        let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)

        capsuleWindow.dismiss { [self] in
            textInjector.inject(text: finalText)
        }
    }

    private func textByAppendingImmediatePunctuation(_ punctuation: String?, to text: String) -> String {
        guard let punctuation, !punctuation.isEmpty else { return text }
        return removingTrailingSentencePunctuation(from: text) + punctuation
    }
}
