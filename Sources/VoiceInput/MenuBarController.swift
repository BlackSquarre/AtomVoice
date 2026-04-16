import Cocoa

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let onLanguageChanged: () -> Void
    private let llmRefiner: LLMRefiner
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?

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
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "语音输入")
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 标题
        let titleItem = NSMenuItem(title: "语音输入", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let instructionItem = NSMenuItem(title: "按住 Fn 键开始录音", action: nil, keyEquivalent: "")
        instructionItem.isEnabled = false
        menu.addItem(instructionItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 VoiceInput", action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.image = icon("info.circle")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // 识别语言
        let langItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
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
        let animItem = NSMenuItem(title: "动画效果", action: nil, keyEquivalent: "")
        animItem.image = icon("sparkles")
        let animMenu = NSMenu()
        let currentAnim = UserDefaults.standard.string(forKey: "animationStyle") ?? "dynamicIsland"

        let diItem = NSMenuItem(title: "灵动岛", action: #selector(selectAnimation(_:)), keyEquivalent: "")
        diItem.target = self
        diItem.representedObject = "dynamicIsland"
        diItem.state = currentAnim == "dynamicIsland" ? .on : .off
        animMenu.addItem(diItem)

        let minimalItem = NSMenuItem(title: "简约模式", action: #selector(selectAnimation(_:)), keyEquivalent: "")
        minimalItem.target = self
        minimalItem.representedObject = "minimal"
        minimalItem.state = currentAnim == "minimal" ? .on : .off
        animMenu.addItem(minimalItem)

        let noneItem = NSMenuItem(title: "无", action: #selector(selectAnimation(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = "none"
        noneItem.state = currentAnim == "none" ? .on : .off
        animMenu.addItem(noneItem)

        // 动画速度（仅灵动岛模式有效）
        let currentSpeed = UserDefaults.standard.string(forKey: "animationSpeed") ?? "medium"
        if currentAnim == "dynamicIsland" {
            animMenu.addItem(.separator())
            let speedLabel = NSMenuItem(title: "动画速度", action: nil, keyEquivalent: "")
            speedLabel.isEnabled = false
            animMenu.addItem(speedLabel)

            for (title, key) in [("慢", "slow"), ("中", "medium"), ("快", "fast")] {
                let item = NSMenuItem(title: title, action: #selector(selectAnimSpeed(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.state = currentSpeed == key ? .on : .off
                item.indentationLevel = 1
                animMenu.addItem(item)
            }
        }

        animItem.submenu = animMenu
        menu.addItem(animItem)

        // 自动标点
        let punctEnabled = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
        let punctItem = NSMenuItem(title: "自动补全标点", action: #selector(togglePunctuation(_:)), keyEquivalent: "")
        punctItem.image = icon("text.badge.plus")
        punctItem.target = self
        punctItem.state = punctEnabled ? .on : .off
        menu.addItem(punctItem)

        // LLM 优化
        let llmItem = NSMenuItem(title: "LLM 文本优化", action: nil, keyEquivalent: "")
        llmItem.image = icon("wand.and.stars")
        let llmMenu = NSMenu()
        let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled")

        let toggleItem = NSMenuItem(
            title: llmEnabled ? "已启用" : "已禁用",
            action: #selector(toggleLLM(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = llmEnabled ? .on : .off
        llmMenu.addItem(toggleItem)

        llmMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.image = icon("gear")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出语音输入", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.image = icon("power")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Helpers

    private func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: - Actions

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

    @objc private func openAbout(_ sender: NSMenuItem) {
        if aboutWindow == nil { aboutWindow = AboutWindowController() }
        aboutWindow?.showWindow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func showAccessibilityWarning() {
        statusItem.button?.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "辅助功能权限丢失")
        let alert = NSAlert()
        alert.messageText = "辅助功能权限已失效"
        alert.informativeText = "请前往系统设置 > 隐私与安全性 > 辅助功能，移除并重新添加语音输入。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "忽略")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "语音输入")
    }
}
