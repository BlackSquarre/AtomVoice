import Cocoa
import AVFoundation
import Speech
import ApplicationServices
import ServiceManagement

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let onLanguageChanged: () -> Void
    private let llmRefiner: LLMRefiner
    private var settingsWindow: SettingsWindowController?
    private var doubaoSettingsWindow: DoubaoSettingsWindowController?
    private var asrSettingsWindow: ASRSettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var permissionsWindow: PermissionsWindowController?
    var onTriggerKeyChanged: ((UInt16) -> Void)?
    var onSherpaDownloadRequested: (() -> Void)?

    private let languages: [(code: String, name: String)] = [
        ("en-US", "English"),
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("es-ES", "Español"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
    ]

    init(onLanguageChanged: @escaping () -> Void, llmRefiner: LLMRefiner) {
        self.onLanguageChanged = onLanguageChanged
        self.llmRefiner = llmRefiner
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.statusBarIcon(accessibilityDescription: loc("app.title"))
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 顶部提示：按住/单击 [触发键] 开始语音输入（Top tip: hold/tap [trigger key] to start voice input）
        let savedKeyCode = UInt16(UserDefaults.standard.integer(forKey: "triggerKeyCode"))
        let triggerOption = TriggerKeyOption.option(for: savedKeyCode == 0 ? 63 : savedKeyCode)
        let isTapMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        let instructionFmt = loc(isTapMode ? "menu.tapKey" : "menu.holdKey")
        let line1 = NSMenuItem(title: String(format: instructionFmt, loc(triggerOption.symbolKey)), action: nil, keyEquivalent: "")
        line1.isEnabled = false
        menu.addItem(line1)
        let line2 = NSMenuItem(title: loc("menu.startVoiceInput"), action: nil, keyEquivalent: "")
        line2.isEnabled = false
        menu.addItem(line2)

        menu.addItem(.separator())

        // 识别语言（Recognition language）
        let langItem = NSMenuItem(title: loc("menu.language"), action: nil, keyEquivalent: "")
        langItem.image = icon("globe")
        let langMenu = NSMenu()
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        for lang in languages {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = lang.code == currentLang ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // 识别引擎（Recognition engine）
        let engineItem = NSMenuItem(title: loc("menu.recognitionEngine"), action: nil, keyEquivalent: "")
        engineItem.image = icon("cpu")
        let engineMenu = NSMenu()
        let currentEngine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
        let engineOptions: [(String, String, String)] = [
            ("apple", loc("menu.recognitionEngine.apple"), "apple.logo"),
            ("sherpaOnnx", loc("menu.recognitionEngine.sherpaOnnx"), "mountain.2.fill"),
            (VolcengineASRSettings.engineCode, loc("menu.recognitionEngine.doubao"), "cloud")
        ]
        for (code, title, iconName) in engineOptions {
            let item = NSMenuItem(title: title, action: #selector(selectRecognitionEngine(_:)), keyEquivalent: "")
            item.image = icon(iconName)
            item.target = self
            item.representedObject = code
            item.state = code == currentEngine ? .on : .off
            engineMenu.addItem(item)
        }
        engineMenu.addItem(.separator())

        // Apple 本地识别（设备端处理）（Apple on-device recognition (local processing)）
        let onDeviceSupported = Self.supportsOnDeviceRecognition(for: currentLang)
        let onDeviceEnabled = UserDefaults.standard.bool(forKey: "appleOnDeviceRecognitionEnabled") && onDeviceSupported
        let onDeviceItem = NSMenuItem(
            title: loc(onDeviceSupported ? "menu.appleOnDeviceSpeech" : "menu.appleOnDeviceSpeech.unavailable"),
            action: #selector(toggleAppleOnDeviceSpeech(_:)),
            keyEquivalent: ""
        )
        onDeviceItem.image = icon("lock.shield")
        onDeviceItem.target = self
        onDeviceItem.state = onDeviceEnabled ? .on : .off
        onDeviceItem.isEnabled = onDeviceSupported
        engineMenu.addItem(onDeviceItem)

        let engineHowtoItem = NSMenuItem(title: loc("menu.engine.howto"), action: #selector(openEngineHowto(_:)), keyEquivalent: "")
        engineHowtoItem.image = icon("questionmark.circle")
        engineHowtoItem.target = self
        engineMenu.addItem(engineHowtoItem)

        engineMenu.addItem(.separator())

        // 识别引擎设置（Recognition engine settings）
        let asrSettingsItem = NSMenuItem(title: loc("menu.asrSettings"), action: #selector(openASRSettings(_:)), keyEquivalent: "")
        asrSettingsItem.target = self
        asrSettingsItem.image = icon("gear")
        engineMenu.addItem(asrSettingsItem)

        engineMenu.addItem(.separator())

        // LLM 优化放在识别引擎菜单末尾，避免主菜单过长（Keep LLM refinement at the end of Recognition Engine to shorten the main menu）
        let llmItem = NSMenuItem(title: loc("menu.llm"), action: nil, keyEquivalent: "")
        llmItem.image = icon("wand.and.stars")
        llmItem.toolTip = loc("tooltip.menu.llm")
        let llmMenu = NSMenu()
        let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled")
        let toggleItem = NSMenuItem(
            title: llmEnabled ? loc("menu.llm.enabled") : loc("menu.llm.disabled"),
            action: #selector(toggleLLM(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = llmEnabled ? .on : .off
        llmMenu.addItem(toggleItem)
        llmMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: loc("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.image = icon("gear")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)
        let howtoItem = NSMenuItem(title: loc("menu.llm.howto"), action: #selector(openLLMHowto(_:)), keyEquivalent: "")
        howtoItem.image = icon("questionmark.circle")
        howtoItem.target = self
        llmMenu.addItem(howtoItem)
        llmItem.submenu = llmMenu
        engineMenu.addItem(llmItem)

        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // 自动标点（Auto punctuation）
        let punctEnabled = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
        let punctItem = NSMenuItem(title: loc("menu.punctuation"), action: #selector(togglePunctuation(_:)), keyEquivalent: "")
        punctItem.image = icon("text.badge.plus")
        punctItem.target = self
        punctItem.state = punctEnabled ? .on : .off
        punctItem.toolTip = loc("tooltip.menu.punctuation")
        menu.addItem(punctItem)

        menu.addItem(.separator())

        // 输入方式: 单击说话 or 长按说话（Input mode: tap to speak or hold to speak）
        let inputModeItem = NSMenuItem(title: loc("menu.inputMode"), action: nil, keyEquivalent: "")
        inputModeItem.image = icon("waveform")
        inputModeItem.toolTip = loc("tooltip.menu.inputMode")
        let inputModeMenu = NSMenu()
        let tapItem = NSMenuItem(title: loc("menu.inputMode.tap"), action: #selector(selectInputModeTap(_:)), keyEquivalent: "")
        tapItem.target = self
        tapItem.state = isTapMode ? .on : .off
        inputModeMenu.addItem(tapItem)
        let holdItem = NSMenuItem(title: loc("menu.inputMode.hold"), action: #selector(selectInputModeHold(_:)), keyEquivalent: "")
        holdItem.target = self
        holdItem.state = !isTapMode ? .on : .off
        inputModeMenu.addItem(holdItem)
        inputModeMenu.addItem(.separator())
        let liveInsertionItem = NSMenuItem(title: loc("menu.inputMode.liveInsertion"), action: #selector(toggleAppleLiveInsertion(_:)), keyEquivalent: "")
        liveInsertionItem.target = self
        liveInsertionItem.state = UserDefaults.standard.bool(forKey: "appleLiveInsertionEnabled") ? .on : .off
        liveInsertionItem.isEnabled = currentEngine == "apple"
        liveInsertionItem.toolTip = loc("menu.inputMode.liveInsertion.tooltip")
        inputModeMenu.addItem(liveInsertionItem)
        if isTapMode {
            inputModeMenu.addItem(.separator())
            let durationLabel = NSMenuItem(title: loc("menu.silence.duration"), action: nil, keyEquivalent: "")
            durationLabel.isEnabled = false
            inputModeMenu.addItem(durationLabel)
            let currentDuration = UserDefaults.standard.double(forKey: "silenceDuration")
            for (title, value) in [("0.5s", 0.5), ("1s", 1.0), ("1.5s", 1.5), ("2s", 2.0), ("3s", 3.0), ("5s", 5.0)] {
                let item = NSMenuItem(title: title, action: #selector(selectSilenceDuration(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value
                item.state = abs(currentDuration - value) < 0.01 ? .on : .off
                item.indentationLevel = 1
                inputModeMenu.addItem(item)
            }
            inputModeMenu.addItem(.separator())
            let noiseLabel = NSMenuItem(title: loc("menu.steadyNoise.sensitivity"), action: nil, keyEquivalent: "")
            noiseLabel.isEnabled = false
            noiseLabel.toolTip = loc("tooltip.menu.steadyNoise")
            inputModeMenu.addItem(noiseLabel)
            let currentSensitivity = UserDefaults.standard.integer(forKey: "steadyNoiseSensitivity")
            for (title, value, tooltip) in [
                (loc("menu.steadyNoise.low"), 0, loc("tooltip.steadyNoise.low")),
                (loc("menu.steadyNoise.medium"), 1, loc("tooltip.steadyNoise.medium")),
                (loc("menu.steadyNoise.high"), 2, loc("tooltip.steadyNoise.high"))
            ] {
                let item = NSMenuItem(title: title, action: #selector(selectSteadyNoiseSensitivity(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value
                item.state = currentSensitivity == value ? .on : .off
                item.toolTip = tooltip
                item.indentationLevel = 1
                inputModeMenu.addItem(item)
            }
        }
        inputModeItem.submenu = inputModeMenu
        menu.addItem(inputModeItem)

        // 触发按键（Trigger key）
        let triggerItem = NSMenuItem(title: loc("menu.triggerKey"), action: nil, keyEquivalent: "")
        triggerItem.image = icon("command")
        triggerItem.toolTip = loc("tooltip.menu.triggerKey")
        let triggerMenu = NSMenu()
        for option in TriggerKeyOption.all {
            let item = NSMenuItem(title: loc(option.locKey), action: #selector(selectTriggerKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Int(option.keyCode))
            item.state = option.keyCode == triggerOption.keyCode ? .on : .off
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        // 音频输入设备（Audio input device）
        let audioInputItem = NSMenuItem(title: loc("menu.audioInput"), action: nil, keyEquivalent: "")
        audioInputItem.image = icon("mic.badge.plus")
        audioInputItem.toolTip = loc("tooltip.menu.audioInput")
        let audioInputMenu = NSMenu()
        let savedUID = UserDefaults.standard.string(forKey: "audioInputDeviceUID") ?? ""
        let defaultItem = NSMenuItem(title: loc("menu.audioInput.default"), action: #selector(selectAudioInput(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = "" as String
        defaultItem.state = savedUID.isEmpty ? .on : .off
        audioInputMenu.addItem(defaultItem)
        audioInputMenu.addItem(.separator())
        for device in AudioEngineController.availableInputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectAudioInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == savedUID ? .on : .off
            audioInputMenu.addItem(item)
        }
        audioInputItem.submenu = audioInputMenu
        menu.addItem(audioInputItem)

        menu.addItem(.separator())

        // 其他设置（子菜单：动画效果、开机启动、权限与帮助、检查更新、关于）（Other settings (submenu: animation, launch at login, permissions & help, check for updates, about)）
        let otherItem = NSMenuItem(title: loc("menu.otherSettings"), action: nil, keyEquivalent: "")
        otherItem.image = icon("ellipsis.circle")
        otherItem.submenu = buildOtherSettingsMenu()
        menu.addItem(otherItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: loc("menu.about"), action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.image = icon("info.circle")
        aboutItem.target = self
        aboutItem.toolTip = loc("tooltip.menu.about")
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: loc("menu.quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.image = icon("power")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func buildOtherSettingsMenu() -> NSMenu {
        let m = NSMenu()

        // 动画效果（Animation style）
        let animItem = NSMenuItem(title: loc("menu.animation"), action: nil, keyEquivalent: "")
        animItem.image = icon("sparkles")
        let animMenu = NSMenu()
        let currentAnim = UserDefaults.standard.string(forKey: "animationStyle") ?? "dynamicIsland"
        for (title, key) in [(loc("menu.animation.dynamicIsland"), "dynamicIsland"),
                              (loc("menu.animation.minimal"),       "minimal"),
                              (loc("menu.animation.none"),          "none")] {
            let item = NSMenuItem(title: title, action: #selector(selectAnimation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = currentAnim == key ? .on : .off
            animMenu.addItem(item)
        }
        let currentSpeed = UserDefaults.standard.string(forKey: "animationSpeed") ?? "medium"
        animMenu.addItem(.separator())
        let speedLabel = NSMenuItem(title: loc("menu.animation.speed"), action: nil, keyEquivalent: "")
        speedLabel.isEnabled = false
        animMenu.addItem(speedLabel)
        for (title, key) in [(loc("menu.animation.slow"), "slow"),
                              (loc("menu.animation.medium"), "medium"),
                              (loc("menu.animation.fast"), "fast")] {
            let item = NSMenuItem(title: title, action: #selector(selectAnimSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = currentSpeed == key ? .on : .off
            item.indentationLevel = 1
            item.isEnabled = currentAnim == "dynamicIsland"
            animMenu.addItem(item)
        }
        animItem.submenu = animMenu
        m.addItem(animItem)

        m.addItem(.separator())

        // 录音时降低系统音量（Lower system volume during recording）
        let lowerVolumeItem = NSMenuItem(title: loc("menu.lowerVolumeOnRecording"),
                                           action: #selector(toggleLowerVolumeOnRecording(_:)),
                                           keyEquivalent: "")
        lowerVolumeItem.image = icon("speaker.wave.1")
        lowerVolumeItem.target = self
        lowerVolumeItem.state = UserDefaults.standard.bool(forKey: "lowerVolumeOnRecording") ? .on : .off
        lowerVolumeItem.toolTip = loc("tooltip.menu.lowerVolumeOnRecording")
        m.addItem(lowerVolumeItem)

        // 开机启动（Launch at login）
        let launchAtLoginItem = NSMenuItem(title: loc("menu.launchAtLogin"),
                                            action: #selector(toggleLaunchAtLogin(_:)),
                                            keyEquivalent: "")
        launchAtLoginItem.image = icon("power.circle")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginItem.toolTip = loc("tooltip.menu.launchAtLogin")
        m.addItem(launchAtLoginItem)

        // 权限与帮助（Permissions & help）
        let helpItem = NSMenuItem(title: loc("menu.help"),
                                   action: #selector(openPermissions(_:)),
                                   keyEquivalent: "")
        helpItem.image = hasAllPermissions ? icon("checkmark.shield") : icon("exclamationmark.shield")
        helpItem.target = self
        helpItem.toolTip = loc("tooltip.menu.help")
        m.addItem(helpItem)

        // 隐私政策（Privacy policy）
        let privacyItem = NSMenuItem(title: loc("menu.privacyPolicy"),
                                     action: #selector(openPrivacyPolicy(_:)),
                                     keyEquivalent: "")
        privacyItem.image = icon("hand.raised")
        privacyItem.target = self
        m.addItem(privacyItem)

        m.addItem(.separator())

        // 检查更新（Check for updates）
        let updateItem = NSMenuItem(title: loc("menu.checkForUpdates"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.image = icon("arrow.down.circle")
        updateItem.target = self
        m.addItem(updateItem)

        let betaItem = NSMenuItem(title: loc("menu.betaUpdates"), action: #selector(toggleBetaUpdates(_:)), keyEquivalent: "")
        betaItem.image = icon("flask")
        betaItem.target = self
        betaItem.state = UserDefaults.standard.bool(forKey: "includeBetaUpdates") ? .on : .off
        betaItem.indentationLevel = 1
        m.addItem(betaItem)

        let oobeItem = NSMenuItem(title: loc("menu.rerunOOBE"), action: #selector(rerunOOBE(_:)), keyEquivalent: "")
        oobeItem.image = icon("sparkles.rectangle.stack")
        oobeItem.target = self
        m.addItem(oobeItem)

        #if DEBUG_BUILD
        m.addItem(.separator())

        // Debug: 测试离线模型下载提示弹窗（Debug: Test offline model download prompt）
        let testOnDeviceAlertItem = NSMenuItem(
            title: loc("menu.debug.testOnDeviceAlert"),
            action: #selector(debugTestOnDeviceAlert(_:)),
            keyEquivalent: ""
        )
        testOnDeviceAlertItem.image = icon("ladybug")
        testOnDeviceAlertItem.target = self
        m.addItem(testOnDeviceAlertItem)
        #endif

        return m
    }

    // MARK: - Launch at Login

    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private var hasAllPermissions: Bool {
        let currentEngine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
        let speechRequired = currentEngine == "apple"
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        (!speechRequired || SFSpeechRecognizer.authorizationStatus() == .authorized) &&
        AXIsProcessTrusted()
    }

    private static func supportsOnDeviceRecognition(for languageCode: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: languageCode))?.supportsOnDeviceRecognition == true
    }

    private func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func statusBarIcon(accessibilityDescription: String) -> NSImage? {
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "atomvoice-status",
                                     withExtension: "svg",
                                     subdirectory: "Icons") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: accessibilityDescription)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = accessibilityDescription
        image?.size = NSSize(width: 17, height: 17)
        return image
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "selectedLanguage")
        if UserDefaults.standard.bool(forKey: "appleOnDeviceRecognitionEnabled"),
           !Self.supportsOnDeviceRecognition(for: code) {
            UserDefaults.standard.set(false, forKey: "appleOnDeviceRecognitionEnabled")
        }
        onLanguageChanged()
        rebuildMenu()
    }

    @objc private func selectRecognitionEngine(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }

        if code == "sherpaOnnx", !sherpaModelsReadyOrSelfHealed() {
            let alert = NSAlert()
            alert.messageText = loc("sherpa.download.title")
            alert.informativeText = loc("sherpa.download.message")
            alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            alert.addButton(withTitle: loc("sherpa.download.confirm"))
            alert.addButton(withTitle: loc("common.cancel"))
            if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
                UserDefaults.standard.set(code, forKey: "recognitionEngine")
                rebuildMenu()
                onSherpaDownloadRequested?()
            }
            return
        }

        if code == VolcengineASRSettings.engineCode {
            if !UserDefaults.standard.bool(forKey: "doubaoASRPrivacyAccepted") {
                let alert = NSAlert()
                alert.messageText = loc("doubao.privacy.title")
                alert.informativeText = loc("doubao.privacy.message")
                alert.icon = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
                alert.addButton(withTitle: loc("doubao.privacy.continue"))
                alert.addButton(withTitle: loc("common.cancel"))
                guard AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn else { return }
                UserDefaults.standard.set(true, forKey: "doubaoASRPrivacyAccepted")
            }

            UserDefaults.standard.set(code, forKey: "recognitionEngine")
            rebuildMenu()
            if !VolcengineASRSettings.hasAPIKey {
                openDoubaoSettingsWindow()
            }
            return
        }

        UserDefaults.standard.set(code, forKey: "recognitionEngine")
        rebuildMenu()
    }

    private func sherpaModelsReadyOrSelfHealed() -> Bool {
        if UserDefaults.standard.bool(forKey: "sherpaModelsReady") { return true }

        if SherpaModelDownloader.allModelsReady || SherpaModelDownloader.repairExtractedFilesIfNeeded() {
            UserDefaults.standard.set(true, forKey: "sherpaModelsReady")
            print("[SherpaOnnx] 菜单选择时检测到完整模型，自动修复 sherpaModelsReady = true")
            return true
        }

        return false
    }

    @objc private func openSherpaFolder(_ sender: NSMenuItem) {
        SherpaOnnxRecognizerController.openSupportDirectory()
    }

    @objc private func openDoubaoSettings(_ sender: NSMenuItem) {
        openDoubaoSettingsWindow()
    }

    @objc private func openASRSettings(_ sender: NSMenuItem) {
        if asrSettingsWindow == nil {
            asrSettingsWindow = ASRSettingsWindowController()
        }
        asrSettingsWindow?.showWindow()
    }

    /// 公开方法：从 AppDelegate / OOBE 完成时调用（Public: called from AppDelegate / OOBE finish）
    func openDoubaoSettingsFromOutside() {
        openDoubaoSettingsWindow()
    }

    /// 公开方法：让外部触发菜单重建（Public: allow external menu rebuild）
    func rebuildMenuPublic() {
        rebuildMenu()
    }

    @objc private func rerunOOBE(_ sender: NSMenuItem) {
        // 重置完成标志并交给 AppDelegate 展示窗口
        // (Reset completion flag and let AppDelegate present the window)
        UserDefaults.standard.set(false, forKey: OOBEWindowController.completionDefaultsKey)
        (NSApp.delegate as? AppDelegate)?.showOOBE()
    }

    private func openDoubaoSettingsWindow() {
        if doubaoSettingsWindow == nil {
            doubaoSettingsWindow = DoubaoSettingsWindowController()
        }
        doubaoSettingsWindow?.showWindow()
    }

    @objc private func toggleAppleOnDeviceSpeech(_ sender: NSMenuItem) {
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        guard Self.supportsOnDeviceRecognition(for: currentLang) else {
            showOnDeviceModelDownloadAlert()
            UserDefaults.standard.set(false, forKey: "appleOnDeviceRecognitionEnabled")
            rebuildMenu()
            return
        }
        let current = UserDefaults.standard.bool(forKey: "appleOnDeviceRecognitionEnabled")
        UserDefaults.standard.set(!current, forKey: "appleOnDeviceRecognitionEnabled")
        rebuildMenu()
    }

    /// 弹窗提示用户下载离线语音模型（Show alert prompting user to download offline speech model）
    private func showOnDeviceModelDownloadAlert() {
        let alert = NSAlert()
        alert.messageText = loc("alert.onDeviceModel.title")
        alert.informativeText = loc("alert.onDeviceModel.message")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("alert.onDeviceModel.openSettings"))
        alert.addButton(withTitle: loc("common.cancel"))

        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    #if DEBUG_BUILD
    @objc private func debugTestOnDeviceAlert(_ sender: NSMenuItem) {
        showOnDeviceModelDownloadAlert()
    }
    #endif

    @objc private func openEngineHowto(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = loc("menu.engine.howto")
        alert.icon = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        alert.accessoryView = makeEngineHowtoTextView()
        alert.addButton(withTitle: loc("common.ok"))
        AppDelegate.runModalAlert(alert)
    }

    private func makeEngineHowtoTextView() -> NSView {
        let text = loc("engine.howto.message")
        let width: CGFloat = 660
        let height: CGFloat = 430

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 32, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(makeEngineHowtoAttributedString(text))

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(usedHeight)))
        }

        scrollView.documentView = textView
        return scrollView
    }

    private func makeEngineHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 2
        headingParagraph.paragraphSpacing = 6
        headingParagraph.lineBreakMode = .byWordWrapping

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 7
        bodyParagraph.lineBreakMode = .byWordWrapping

        let summaryParagraph = NSMutableParagraphStyle()
        summaryParagraph.lineSpacing = 3
        summaryParagraph.paragraphSpacing = 0
        summaryParagraph.lineBreakMode = .byWordWrapping

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let summaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: summaryParagraph,
        ]

        let summaryPrefixes = ["建议", "建議", "Recommendation", "おすすめ", "추천", "Recomendación", "Recommandation", "Empfehlung"]
        var previousLineWasBlank = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousLineWasBlank, result.length > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                previousLineWasBlank = true
                continue
            }

            let attributes: [NSAttributedString.Key: Any]
            if line.hasPrefix("• ") {
                attributes = headingAttributes
            } else if summaryPrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = summaryAttributes
            } else {
                attributes = bodyAttributes
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
            previousLineWasBlank = false
        }

        return result
    }

    private func makeLLMHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 2
        headingParagraph.paragraphSpacing = 6
        headingParagraph.lineBreakMode = .byWordWrapping

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 7
        bodyParagraph.lineBreakMode = .byWordWrapping

        let listParagraph = NSMutableParagraphStyle()
        listParagraph.lineSpacing = 3
        listParagraph.paragraphSpacing = 4
        listParagraph.lineBreakMode = .byWordWrapping
        listParagraph.headIndent = 20
        listParagraph.firstLineHeadIndent = 0

        let noteParagraph = NSMutableParagraphStyle()
        noteParagraph.lineSpacing = 3
        noteParagraph.paragraphSpacing = 0
        noteParagraph.lineBreakMode = .byWordWrapping

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let listAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: listParagraph,
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: noteParagraph,
        ]

        let headingPrefixes = ["LLM", "例如", "使用方法", "For example", "How to use", "例", "使い方", "예", "사용 방법"]
        let notePrefixes = ["开启后", "When enabled", "有効にすると", "활성화하면"]
        var previousLineWasBlank = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousLineWasBlank, result.length > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                previousLineWasBlank = true
                continue
            }

            let attributes: [NSAttributedString.Key: Any]
            if headingPrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = headingAttributes
            } else if notePrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = noteAttributes
            } else if line.hasPrefix("1.") || line.hasPrefix("2.") || line.hasPrefix("3.") || line.hasPrefix("4.") {
                attributes = listAttributes
            } else {
                attributes = bodyAttributes
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
            previousLineWasBlank = false
        }

        return result
    }

    @objc private func selectTriggerKey(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let keyCode = UInt16(num.intValue)
        UserDefaults.standard.set(Int(keyCode), forKey: "triggerKeyCode")
        onTriggerKeyChanged?(keyCode)
        rebuildMenu()
    }

    @objc private func selectAudioInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "audioInputDeviceUID")
        rebuildMenu()
    }

    @objc private func selectAnimation(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        UserDefaults.standard.set(style, forKey: "animationStyle")
        rebuildMenu()
    }

    @objc private func selectAnimSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? String else { return }
        UserDefaults.standard.set(speed, forKey: "animationSpeed")
        rebuildMenu()
    }

    @objc private func selectInputModeTap(_ sender: NSMenuItem) {
        UserDefaults.standard.set(true, forKey: "silenceAutoStopEnabled")
        rebuildMenu()
    }

    @objc private func selectInputModeHold(_ sender: NSMenuItem) {
        UserDefaults.standard.set(false, forKey: "silenceAutoStopEnabled")
        rebuildMenu()
    }

    @objc private func toggleAppleLiveInsertion(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "appleLiveInsertionEnabled")
        UserDefaults.standard.set(!current, forKey: "appleLiveInsertionEnabled")
        rebuildMenu()
    }

    @objc private func selectSilenceDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(duration, forKey: "silenceDuration")
        rebuildMenu()
    }

    @objc private func selectSteadyNoiseSensitivity(_ sender: NSMenuItem) {
        guard let sensitivity = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(sensitivity, forKey: "steadyNoiseSensitivity")
        rebuildMenu()
    }

    @objc private func togglePunctuation(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
        UserDefaults.standard.set(!current, forKey: "autoPunctuationEnabled")
        rebuildMenu()
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "llmEnabled")
        UserDefaults.standard.set(!current, forKey: "llmEnabled")
        rebuildMenu()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(llmRefiner: llmRefiner)
        }
        settingsWindow?.showWindow()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if isLaunchAtLoginEnabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                print("[LaunchAtLogin] Error: \(error)")
            }
        }
        rebuildMenu()
    }

    @objc private func toggleLowerVolumeOnRecording(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "lowerVolumeOnRecording")
        UserDefaults.standard.set(!current, forKey: "lowerVolumeOnRecording")
        rebuildMenu()
    }

    @objc private func openPermissions(_ sender: NSMenuItem) {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController() }
        permissionsWindow?.showWindow()
    }

    @objc private func openPrivacyPolicy(_ sender: NSMenuItem) {
        let lang = Locale.preferredLanguages.first ?? "en"
        let file: String
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
            file = "PRIVACY-zh-Hant.md"
        } else if lang.hasPrefix("zh") {
            file = "PRIVACY-zh-Hans.md"
        } else if lang.hasPrefix("ja") {
            file = "PRIVACY-ja.md"
        } else if lang.hasPrefix("ko") {
            file = "PRIVACY-ko.md"
        } else if lang.hasPrefix("es") {
            file = "PRIVACY-es.md"
        } else if lang.hasPrefix("fr") {
            file = "PRIVACY-fr.md"
        } else if lang.hasPrefix("de") {
            file = "PRIVACY-de.md"
        } else {
            file = "PRIVACY-en.md"
        }
        let url = URL(string: "https://github.com/BlackSquarre/AtomVoice/blob/main/README/privacy/\(file)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleBetaUpdates(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "includeBetaUpdates")
        UserDefaults.standard.set(!current, forKey: "includeBetaUpdates")
        rebuildMenu()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        UpdateChecker.shared.checkForUpdates(silent: false)
    }

    @objc private func openLLMHowto(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = loc("menu.llm.howto")
        alert.icon = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        alert.accessoryView = makeLLMHowtoTextView()
        alert.addButton(withTitle: loc("common.ok"))
        AppDelegate.runModalAlert(alert)
    }

    private func makeLLMHowtoTextView() -> NSView {
        let text = loc("llm.howto.message")
        let width: CGFloat = 560
        let height: CGFloat = 380

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 32, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(makeLLMHowtoAttributedString(text))

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(usedHeight)))
        }

        scrollView.documentView = textView
        return scrollView
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        if aboutWindow == nil { aboutWindow = AboutWindowController() }
        aboutWindow?.showWindow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func showAccessibilityWarning() {
        statusItem.button?.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: loc("accessibility.warning.title"))
        let alert = NSAlert()
        alert.messageText = loc("accessibility.warning.title")
        alert.informativeText = loc("accessibility.warning.message")
        alert.addButton(withTitle: loc("accessibility.openSettings"))
        alert.addButton(withTitle: loc("accessibility.ignore"))
        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        statusItem.button?.image = Self.statusBarIcon(accessibilityDescription: loc("app.title"))
    }
}
