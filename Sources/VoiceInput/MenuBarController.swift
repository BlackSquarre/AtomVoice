import Cocoa

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let onLanguageChanged: () -> Void
    private let llmRefiner: LLMRefiner
    private var settingsWindow: SettingsWindowController?

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

        let titleItem = NSMenuItem(title: "语音输入", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let instructionItem = NSMenuItem(title: "按住 Fn 键开始录音", action: nil, keyEquivalent: "")
        instructionItem.isEnabled = false
        menu.addItem(instructionItem)

        menu.addItem(.separator())

        // 识别语言
        let langItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
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

        // 自动标点
        let punctEnabled = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
        let punctItem = NSMenuItem(
            title: "自动补全标点",
            action: #selector(togglePunctuation(_:)),
            keyEquivalent: ""
        )
        punctItem.target = self
        punctItem.state = punctEnabled ? .on : .off
        menu.addItem(punctItem)

        // LLM 优化
        let llmItem = NSMenuItem(title: "LLM 文本优化", action: nil, keyEquivalent: "")
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
        settingsItem.target = self
        llmMenu.addItem(settingsItem)

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出语音输入", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "selectedLanguage")
        onLanguageChanged()
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

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
