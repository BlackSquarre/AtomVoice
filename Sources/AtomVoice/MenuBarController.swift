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
    private var aboutWindow: AboutWindowController?
    private var permissionsWindow: PermissionsWindowController?
    var onTriggerKeyChanged: ((UInt16) -> Void)?

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
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: loc("app.title"))
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 顶部提示：按住/单击 [触发键] 开始语音输入
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

        // 识别语言
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

        // 自动标点
        let punctEnabled = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
        let punctItem = NSMenuItem(title: loc("menu.punctuation"), action: #selector(togglePunctuation(_:)), keyEquivalent: "")
        punctItem.image = icon("text.badge.plus")
        punctItem.target = self
        punctItem.state = punctEnabled ? .on : .off
        menu.addItem(punctItem)

        // LLM 优化
        let llmItem = NSMenuItem(title: loc("menu.llm"), action: nil, keyEquivalent: "")
        llmItem.image = icon("wand.and.stars")
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
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // 输入方式: 单击说话 or 长按说话
        let inputModeItem = NSMenuItem(title: loc("menu.inputMode"), action: nil, keyEquivalent: "")
        inputModeItem.image = icon("waveform")
        let inputModeMenu = NSMenu()
        let tapItem = NSMenuItem(title: loc("menu.inputMode.tap"), action: #selector(selectInputModeTap(_:)), keyEquivalent: "")
        tapItem.target = self
        tapItem.state = isTapMode ? .on : .off
        inputModeMenu.addItem(tapItem)
        let holdItem = NSMenuItem(title: loc("menu.inputMode.hold"), action: #selector(selectInputModeHold(_:)), keyEquivalent: "")
        holdItem.target = self
        holdItem.state = !isTapMode ? .on : .off
        inputModeMenu.addItem(holdItem)
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
        }
        inputModeItem.submenu = inputModeMenu
        menu.addItem(inputModeItem)

        // 触发按键
        let triggerItem = NSMenuItem(title: loc("menu.triggerKey"), action: nil, keyEquivalent: "")
        triggerItem.image = icon("command")
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

        // 音频输入设备
        let audioInputItem = NSMenuItem(title: loc("menu.audioInput"), action: nil, keyEquivalent: "")
        audioInputItem.image = icon("mic.badge.plus")
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

        // 其他设置（子菜单：动画效果、开机启动、权限与帮助、检查更新、关于）
        let otherItem = NSMenuItem(title: loc("menu.otherSettings"), action: nil, keyEquivalent: "")
        otherItem.image = icon("ellipsis.circle")
        otherItem.submenu = buildOtherSettingsMenu()
        menu.addItem(otherItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: loc("menu.about"), action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.image = icon("info.circle")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: loc("menu.quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.image = icon("power")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func buildOtherSettingsMenu() -> NSMenu {
        let m = NSMenu()

        // 动画效果
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

        // 开机启动
        let launchAtLoginItem = NSMenuItem(title: loc("menu.launchAtLogin"),
                                           action: #selector(toggleLaunchAtLogin(_:)),
                                           keyEquivalent: "")
        launchAtLoginItem.image = icon("power.circle")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        m.addItem(launchAtLoginItem)

        // 权限与帮助
        let helpItem = NSMenuItem(title: loc("menu.help"),
                                  action: #selector(openPermissions(_:)),
                                  keyEquivalent: "")
        helpItem.image = hasAllPermissions ? icon("checkmark.shield") : icon("exclamationmark.shield")
        helpItem.target = self
        m.addItem(helpItem)

        m.addItem(.separator())

        // 检查更新
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
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
        AXIsProcessTrusted()
    }

    private func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "selectedLanguage")
        onLanguageChanged()
        rebuildMenu()
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

    @objc private func selectSilenceDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(duration, forKey: "silenceDuration")
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

    @objc private func openPermissions(_ sender: NSMenuItem) {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController() }
        permissionsWindow?.showWindow()
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
        alert.accessoryView = makeLLMHowtoTextView()
        alert.addButton(withTitle: loc("common.ok"))
        AppDelegate.runModalAlert(alert)
    }

    private func makeLLMHowtoTextView() -> NSView {
        let text = loc("llm.howto.message")
        let width: CGFloat = 560
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let height = ceil((text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        ).height) + 4

        let textField = NSTextField(wrappingLabelWithString: text)
        textField.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textField.font = font
        textField.textColor = .secondaryLabelColor
        textField.maximumNumberOfLines = 0
        textField.preferredMaxLayoutWidth = width
        return textField
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
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: loc("app.title"))
    }
}
