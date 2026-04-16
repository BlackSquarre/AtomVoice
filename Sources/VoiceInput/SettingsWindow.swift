import Cocoa

final class SettingsWindowController {
    private var window: NSWindow?
    private var providerPopup: NSPopUpButton!
    private var apiBaseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var delayField: NSTextField!
    private var statusLabel: NSTextField!
    private let llmRefiner: LLMRefiner

    // MARK: - 服务商预设
    struct Provider {
        let name: String
        let baseURL: String
        let defaultModel: String
    }

    private let providers: [Provider] = [
        Provider(name: "OpenAI",           baseURL: "https://api.openai.com/v1",                            defaultModel: "gpt-4o-mini"),
        Provider(name: "DeepSeek",         baseURL: "https://api.deepseek.com/v1",                          defaultModel: "deepseek-chat"),
        Provider(name: "Moonshot (Kimi)",  baseURL: "https://api.moonshot.cn/v1",                           defaultModel: "moonshot-v1-8k"),
        Provider(name: "阿里云百炼 (Qwen)",  baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",   defaultModel: "qwen-turbo"),
        Provider(name: "智谱 AI (GLM)",     baseURL: "https://open.bigmodel.cn/api/paas/v4",                 defaultModel: "glm-4-flash"),
        Provider(name: "零一万物 (Yi)",      baseURL: "https://api.lingyiwanwu.com/v1",                       defaultModel: "yi-lightning"),
        Provider(name: "Groq",             baseURL: "https://api.groq.com/openai/v1",                       defaultModel: "llama-3.3-70b-versatile"),
        Provider(name: "Ollama (本地)",     baseURL: "http://localhost:11434/v1",                            defaultModel: "llama3"),
        Provider(name: "自定义",            baseURL: "",                                                     defaultModel: ""),
    ]

    init(llmRefiner: LLMRefiner) {
        self.llmRefiner = llmRefiner
    }

    func showWindow() {
        if let window = window {
            refreshFields()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM 文本优化设置"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let padding: CGFloat = 24
        let labelWidth: CGFloat = 110
        let fieldHeight: CGFloat = 28
        let rowSpacing: CGFloat = 44
        var y: CGFloat = 348

        // 服务商选择
        contentView.addSubview(makeLabel("服务商:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fieldHeight)))
        providerPopup = NSPopUpButton(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fieldHeight))
        for p in providers { providerPopup.addItem(withTitle: p.name) }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        contentView.addSubview(providerPopup)
        y -= rowSpacing

        // API 地址
        contentView.addSubview(makeLabel("API 地址:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fieldHeight)))
        apiBaseURLField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fieldHeight))
        apiBaseURLField.placeholderString = "https://api.openai.com/v1"
        contentView.addSubview(apiBaseURLField)
        y -= rowSpacing

        // API 密钥
        contentView.addSubview(makeLabel("API 密钥:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fieldHeight)))
        apiKeyField = NSSecureTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fieldHeight))
        apiKeyField.placeholderString = "sk-..."
        styleTextField(apiKeyField)
        contentView.addSubview(apiKeyField)
        y -= rowSpacing

        // 模型
        contentView.addSubview(makeLabel("模型:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fieldHeight)))
        modelField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fieldHeight))
        modelField.placeholderString = "gpt-4o-mini"
        contentView.addSubview(modelField)
        y -= rowSpacing

        // 结果展示延迟
        contentView.addSubview(makeLabel("结果展示延迟:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fieldHeight)))
        delayField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 60, height: fieldHeight))
        delayField.placeholderString = "0.3"
        contentView.addSubview(delayField)

        let unitLabel = NSTextField(labelWithString: "秒（0 为立即注入）")
        unitLabel.frame = NSRect(x: padding + labelWidth + 8 + 68, y: y + 4, width: 200, height: 20)
        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(unitLabel)
        y -= 52

        // 分割线
        let separator = NSBox()
        separator.frame = NSRect(x: padding, y: y, width: 500 - padding * 2, height: 1)
        separator.boxType = .separator
        contentView.addSubview(separator)
        y -= 36

        // 状态标签
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: padding, y: y, width: 310, height: 20)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // 按钮
        let btnW: CGFloat = 88
        let btnH: CGFloat = 32
        let btnY = y - 2

        let testButton = makeButton("测试连接", action: #selector(testConnection(_:)),
                                    frame: NSRect(x: 500 - padding - btnW * 3 - 10 * 2, y: btnY, width: btnW, height: btnH))
        contentView.addSubview(testButton)

        let saveButton = makeButton("保存", action: #selector(saveSettings(_:)),
                                    frame: NSRect(x: 500 - padding - btnW * 2 - 10, y: btnY, width: btnW, height: btnH),
                                    isPrimary: true)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        let cancelButton = makeButton("取消", action: #selector(cancelSettings(_:)),
                                      frame: NSRect(x: 500 - padding - btnW, y: btnY, width: btnW, height: btnH))
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        self.window = window
        refreshFields()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Factory Helpers

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeTextField(frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        styleTextField(field)
        return field
    }

    private func styleTextField(_ field: NSTextField) {
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
    }

    private func makeButton(_ title: String, action: Selector, frame: NSRect, isPrimary: Bool = false) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.frame = frame
        if #available(macOS 26.0, *) {
            btn.bezelStyle = .glass
        } else {
            btn.bezelStyle = .rounded
        }
        if isPrimary {
            btn.hasDestructiveAction = false
            btn.keyEquivalentModifierMask = []
        }
        return btn
    }

    // MARK: - State

    private func refreshFields() {
        let savedURL   = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let savedKey   = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let savedModel = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"
        let savedDelay = UserDefaults.standard.double(forKey: "llmResultDelay")

        // 根据已存 URL 自动选中对应服务商
        let matchIndex = providers.firstIndex { $0.baseURL == savedURL } ?? (providers.count - 1)
        providerPopup?.selectItem(at: matchIndex)

        apiBaseURLField?.stringValue = savedURL
        apiKeyField?.stringValue     = savedKey
        modelField?.stringValue      = savedModel
        delayField?.stringValue      = String(format: "%.1f", savedDelay > 0 ? savedDelay : 0.3)
        statusLabel?.stringValue     = ""
    }

    // MARK: - Actions

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let p = providers[sender.indexOfSelectedItem]
        if p.name == "自定义" {
            // 自定义：清空 URL 和模型，让用户自己填
            apiBaseURLField.stringValue = ""
            modelField.stringValue = ""
            apiBaseURLField.becomeFirstResponder()
        } else {
            apiBaseURLField.stringValue = p.baseURL
            // 只在模型字段为空或是上一个预设的默认模型时才替换
            modelField.stringValue = p.defaultModel
        }
    }

    @objc private func testConnection(_ sender: NSButton) {
        let origBase  = UserDefaults.standard.string(forKey: "llmAPIBaseURL")
        let origKey   = UserDefaults.standard.string(forKey: "llmAPIKey")
        let origModel = UserDefaults.standard.string(forKey: "llmModel")

        UserDefaults.standard.set(apiBaseURLField.stringValue, forKey: "llmAPIBaseURL")
        UserDefaults.standard.set(apiKeyField.stringValue,     forKey: "llmAPIKey")
        UserDefaults.standard.set(modelField.stringValue,      forKey: "llmModel")

        statusLabel.stringValue = "正在测试..."
        statusLabel.textColor = .secondaryLabelColor

        llmRefiner.testConnection { [weak self] success, message in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = success ? "连接成功!" : "连接失败: \(message)"
                self?.statusLabel.textColor = success ? .systemGreen : .systemRed

                if let base  = origBase  { UserDefaults.standard.set(base,  forKey: "llmAPIBaseURL") }
                if let key   = origKey   { UserDefaults.standard.set(key,   forKey: "llmAPIKey") }
                if let model = origModel { UserDefaults.standard.set(model, forKey: "llmModel") }
            }
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        UserDefaults.standard.set(apiBaseURLField.stringValue, forKey: "llmAPIBaseURL")
        UserDefaults.standard.set(apiKeyField.stringValue,     forKey: "llmAPIKey")
        UserDefaults.standard.set(modelField.stringValue,      forKey: "llmModel")
        let delayValue = Double(delayField.stringValue) ?? 0.3
        UserDefaults.standard.set(max(0, delayValue), forKey: "llmResultDelay")
        statusLabel.stringValue = "已保存"
        statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}
