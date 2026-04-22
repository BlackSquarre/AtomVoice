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

    private let languages: [(code: String, name: String)] = [
        ("en-US", "English"),
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
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

        let titleItem = NSMenuItem(title: loc("app.title"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let instructionItem = NSMenuItem(title: loc("menu.holdFn"), action: nil, keyEquivalent: "")
        instructionItem.isEnabled = false
        menu.addItem(instructionItem)

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

        menu.addItem(.separator())

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

        // 动画速度
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
        menu.addItem(animItem)

        // 输入方式: 单击说话 or 长按说话
        let inputModeItem = NSMenuItem(title: loc("menu.inputMode"), action: nil, keyEquivalent: "")
        inputModeItem.image = icon("hand.point.up.left")
        let inputModeMenu = NSMenu()
        let isTapMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")

        let tapItem = NSMenuItem(title: loc("menu.inputMode.tap"), action: #selector(selectInputModeTap(_:)), keyEquivalent: "")
        tapItem.target = self
        tapItem.state = isTapMode ? .on : .off
        inputModeMenu.addItem(tapItem)

        let holdItem = NSMenuItem(title: loc("menu.inputMode.hold"), action: #selector(selectInputModeHold(_:)), keyEquivalent: "")
        holdItem.target = self
        holdItem.state = !isTapMode ? .on : .off
        inputModeMenu.addItem(holdItem)

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
            item.isEnabled = isTapMode
            inputModeMenu.addItem(item)
        }

        inputModeItem.submenu = inputModeMenu
        menu.addItem(inputModeItem)

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

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // 开机启动
        let launchAtLoginItem = NSMenuItem(title: loc("menu.launchAtLogin"),
                                           action: #selector(toggleLaunchAtLogin(_:)),
                                           keyEquivalent: "")
        launchAtLoginItem.image = icon("power.circle")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        // 权限与帮助
        let helpItem = NSMenuItem(title: loc("menu.help"),
                                  action: #selector(openPermissions(_:)),
                                  keyEquivalent: "")
        helpItem.image = hasAllPermissions ? icon("checkmark.shield") : icon("exclamationmark.shield")
        helpItem.target = self
        menu.addItem(helpItem)

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
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: loc("app.title"))
    }
}
