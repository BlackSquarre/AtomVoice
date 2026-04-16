import Cocoa

// MARK: - 服务商数据模型

struct LLMProvider: Codable {
    var name: String
    var baseURL: String
    var defaultModel: String
}

// MARK: - 服务商持久化

final class ProviderStore {
    static let key = "llmProviders"

    static let defaults: [LLMProvider] = [
        LLMProvider(name: "OpenAI",           baseURL: "https://api.openai.com/v1",                            defaultModel: "gpt-4o-mini"),
        LLMProvider(name: "DeepSeek",         baseURL: "https://api.deepseek.com/v1",                          defaultModel: "deepseek-chat"),
        LLMProvider(name: "Moonshot (Kimi)",  baseURL: "https://api.moonshot.cn/v1",                           defaultModel: "moonshot-v1-8k"),
        LLMProvider(name: "阿里云百炼 (Qwen)", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",    defaultModel: "qwen-turbo"),
        LLMProvider(name: "智谱 AI (GLM)",    baseURL: "https://open.bigmodel.cn/api/paas/v4",                  defaultModel: "glm-4-flash"),
        LLMProvider(name: "零一万物 (Yi)",     baseURL: "https://api.lingyiwanwu.com/v1",                        defaultModel: "yi-lightning"),
        LLMProvider(name: "Groq",             baseURL: "https://api.groq.com/openai/v1",                        defaultModel: "llama-3.3-70b-versatile"),
        LLMProvider(name: "Ollama (本地)",    baseURL: "http://localhost:11434/v1",                              defaultModel: "qwen2.5:1.5b"),
        LLMProvider(name: "自定义",           baseURL: "",                                                       defaultModel: ""),
    ]

    static func load() -> [LLMProvider] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LLMProvider].self, from: data) else {
            return defaults
        }
        return list
    }

    static func save(_ list: [LLMProvider]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 服务商编辑器（Sheet）

final class ProviderEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var sheet: NSWindow!
    private var tableView: NSTableView!
    private var nameField: NSTextField!
    private var urlField: NSTextField!
    private var modelField: NSTextField!
    private var deleteButton: NSButton!
    private var providers: [LLMProvider] = []
    var onDone: (([LLMProvider]) -> Void)?

    func show(in parent: NSWindow) {
        providers = ProviderStore.load()
        buildSheet()
        parent.beginSheet(sheet, completionHandler: nil)
    }

    private func buildSheet() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "管理服务商"

        let cv = sheet.contentView!
        let padding: CGFloat = 16

        // 表格
        let scroll = NSScrollView(frame: NSRect(x: padding, y: 160, width: 488, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true

        for (id, title) in [("name","名称"), ("url","API 地址"), ("model","默认模型")] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.isEditable = true
            switch id {
            case "name":  col.width = 110
            case "url":   col.width = 240
            default:      col.width = 120
            }
            tableView.addTableColumn(col)
        }
        scroll.documentView = tableView
        cv.addSubview(scroll)

        // +/- 按钮
        let addBtn = NSButton(title: "+", target: self, action: #selector(addProvider))
        addBtn.frame = NSRect(x: padding, y: 128, width: 32, height: 26)
        addBtn.bezelStyle = .rounded
        cv.addSubview(addBtn)

        deleteButton = NSButton(title: "−", target: self, action: #selector(deleteProvider))
        deleteButton.frame = NSRect(x: padding + 36, y: 128, width: 32, height: 26)
        deleteButton.bezelStyle = .rounded
        cv.addSubview(deleteButton)

        // 分割线
        let sep = NSBox(frame: NSRect(x: padding, y: 118, width: 488, height: 1))
        sep.boxType = .separator
        cv.addSubview(sep)

        // 编辑区（点击行后填入）
        let fh: CGFloat = 24
        let lw: CGFloat = 60
        let fx = padding + lw + 8
        let fw: CGFloat = 420

        func addRow(_ label: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: padding, y: y, width: lw, height: fh)
            l.alignment = .right; l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            cv.addSubview(l)
            let f = NSTextField(frame: NSRect(x: fx, y: y, width: fw, height: fh))
            f.bezelStyle = .roundedBezel; f.font = .systemFont(ofSize: 12)
            f.delegate = self as? NSTextFieldDelegate
            cv.addSubview(f)
            return f
        }
        nameField  = addRow("名称:", y: 84)
        urlField   = addRow("地址:", y: 56)
        modelField = addRow("模型:", y: 28)

        nameField.target  = self; nameField.action  = #selector(fieldEdited(_:))
        urlField.target   = self; urlField.action   = #selector(fieldEdited(_:))
        modelField.target = self; modelField.action = #selector(fieldEdited(_:))

        // 完成按钮
        let doneBtn = NSButton(title: "完成", target: self, action: #selector(done))
        doneBtn.frame = NSRect(x: 520 - padding - 80, y: 28 - 4, width: 80, height: 30)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)
    }

    // MARK: TableView

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let p = providers[row]
        switch tableColumn?.identifier.rawValue {
        case "name":  return p.name
        case "url":   return p.baseURL
        case "model": return p.defaultModel
        default:      return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue obj: Any?, for col: NSTableColumn?, row: Int) {
        guard let val = obj as? String else { return }
        switch col?.identifier.rawValue {
        case "name":  providers[row].name = val
        case "url":   providers[row].baseURL = val
        case "model": providers[row].defaultModel = val
        default: break
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let p = providers[row]
        nameField.stringValue  = p.name
        urlField.stringValue   = p.baseURL
        modelField.stringValue = p.defaultModel
    }

    // MARK: Actions

    @objc private func addProvider() {
        providers.append(LLMProvider(name: "新服务商", baseURL: "", defaultModel: ""))
        tableView.reloadData()
        let last = providers.count - 1
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
        nameField.stringValue = providers[last].name
        urlField.stringValue = ""
        modelField.stringValue = ""
        nameField.becomeFirstResponder()
    }

    @objc private func deleteProvider() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        providers.remove(at: row)
        tableView.reloadData()
        // 选中相邻行
        if !providers.isEmpty {
            let next = min(row, providers.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        } else {
            nameField.stringValue = ""; urlField.stringValue = ""; modelField.stringValue = ""
        }
    }

    @objc private func fieldEdited(_ sender: NSTextField) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        providers[row].name         = nameField.stringValue
        providers[row].baseURL      = urlField.stringValue
        providers[row].defaultModel = modelField.stringValue
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(0..<3))
    }

    @objc private func done() {
        ProviderStore.save(providers)
        onDone?(providers)
        sheet.sheetParent?.endSheet(sheet)
    }
}

// MARK: - 设置窗口

final class SettingsWindowController {
    private var window: NSWindow?
    private var providerPopup: NSPopUpButton!
    private var apiBaseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var delayField: NSTextField!
    private var statusLabel: NSTextField!
    private let llmRefiner: LLMRefiner
    private var providerEditor: ProviderEditorController?
    private var providers: [LLMProvider] = []

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

        let cv = NSView(frame: window.contentView!.bounds)
        cv.autoresizingMask = [.width, .height]
        window.contentView = cv

        let padding: CGFloat = 24
        let labelWidth: CGFloat = 110
        let fh: CGFloat = 28
        let spacing: CGFloat = 44
        var y: CGFloat = 348

        // 服务商行（popup + 编辑按钮）
        cv.addSubview(makeLabel("服务商:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fh)))
        providerPopup = NSPopUpButton(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 236, height: fh))
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        cv.addSubview(providerPopup)

        let editBtn = NSButton(title: "管理...", target: self, action: #selector(editProviders(_:)))
        editBtn.frame = NSRect(x: padding + labelWidth + 8 + 242, y: y, width: 72, height: fh)
        editBtn.bezelStyle = .rounded
        cv.addSubview(editBtn)
        y -= spacing

        // API 地址
        cv.addSubview(makeLabel("API 地址:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fh)))
        apiBaseURLField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fh))
        apiBaseURLField.placeholderString = "https://api.openai.com/v1"
        cv.addSubview(apiBaseURLField)
        y -= spacing

        // API 密钥
        cv.addSubview(makeLabel("API 密钥:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fh)))
        apiKeyField = NSSecureTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fh))
        apiKeyField.placeholderString = "sk-..."
        styleTextField(apiKeyField)
        cv.addSubview(apiKeyField)
        y -= spacing

        // 模型
        cv.addSubview(makeLabel("模型:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fh)))
        modelField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 320, height: fh))
        modelField.placeholderString = "gpt-4o-mini"
        cv.addSubview(modelField)
        y -= spacing

        // 延迟
        cv.addSubview(makeLabel("结果展示延迟:", frame: NSRect(x: padding, y: y, width: labelWidth, height: fh)))
        delayField = makeTextField(frame: NSRect(x: padding + labelWidth + 8, y: y, width: 60, height: fh))
        delayField.placeholderString = "0.3"
        cv.addSubview(delayField)
        let unitLabel = NSTextField(labelWithString: "秒（0 为立即注入）")
        unitLabel.frame = NSRect(x: padding + labelWidth + 76, y: y + 4, width: 200, height: 20)
        unitLabel.font = .systemFont(ofSize: 12); unitLabel.textColor = .tertiaryLabelColor
        cv.addSubview(unitLabel)
        y -= 52

        // 分割线
        let sep = NSBox(frame: NSRect(x: padding, y: y, width: 500 - padding * 2, height: 1))
        sep.boxType = .separator; cv.addSubview(sep)
        y -= 36

        // 状态
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: padding, y: y, width: 310, height: 20)
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        cv.addSubview(statusLabel)

        // 按钮
        let btnW: CGFloat = 88, btnH: CGFloat = 32, btnY = y - 2
        cv.addSubview(makeButton("测试连接", action: #selector(testConnection(_:)),
                                  frame: NSRect(x: 500 - padding - btnW * 3 - 20, y: btnY, width: btnW, height: btnH)))
        let saveBtn = makeButton("保存", action: #selector(saveSettings(_:)),
                                  frame: NSRect(x: 500 - padding - btnW * 2 - 10, y: btnY, width: btnW, height: btnH), isPrimary: true)
        saveBtn.keyEquivalent = "\r"; cv.addSubview(saveBtn)
        let cancelBtn = makeButton("取消", action: #selector(cancelSettings(_:)),
                                    frame: NSRect(x: 500 - padding - btnW, y: btnY, width: btnW, height: btnH))
        cancelBtn.keyEquivalent = "\u{1b}"; cv.addSubview(cancelBtn)

        self.window = window
        refreshFields()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = frame; l.alignment = .right
        l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabelColor
        return l
    }
    private func makeTextField(frame: NSRect) -> NSTextField {
        let f = NSTextField(frame: frame)
        styleTextField(f); return f
    }
    private func styleTextField(_ f: NSTextField) {
        f.bezelStyle = .roundedBezel; f.font = .systemFont(ofSize: 13)
    }
    private func makeButton(_ title: String, action: Selector, frame: NSRect, isPrimary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.frame = frame
        if #available(macOS 26.0, *) { b.bezelStyle = .glass } else { b.bezelStyle = .rounded }
        return b
    }

    private func rebuildPopup() {
        providers = ProviderStore.load()
        providerPopup.removeAllItems()
        providers.forEach { providerPopup.addItem(withTitle: $0.name) }
    }

    private func refreshFields() {
        rebuildPopup()
        let savedURL   = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let matchIndex = providers.firstIndex { $0.baseURL == savedURL } ?? (providers.count - 1)
        providerPopup.selectItem(at: matchIndex)
        apiBaseURLField?.stringValue = savedURL
        apiKeyField?.stringValue     = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        modelField?.stringValue      = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"
        let delay = UserDefaults.standard.double(forKey: "llmResultDelay")
        delayField?.stringValue      = String(format: "%.1f", delay > 0 ? delay : 0.3)
        statusLabel?.stringValue     = ""
    }

    // MARK: - Actions

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let p = providers[sender.indexOfSelectedItem]
        if p.baseURL.isEmpty {
            apiBaseURLField.stringValue = ""
            modelField.stringValue = ""
            apiBaseURLField.becomeFirstResponder()
        } else {
            apiBaseURLField.stringValue = p.baseURL
            modelField.stringValue = p.defaultModel
        }
    }

    @objc private func editProviders(_ sender: NSButton) {
        guard let window = window else { return }
        let editor = ProviderEditorController()
        editor.onDone = { [weak self] _ in
            self?.refreshFields()
        }
        providerEditor = editor
        editor.show(in: window)
    }

    @objc private func testConnection(_ sender: NSButton) {
        let origBase  = UserDefaults.standard.string(forKey: "llmAPIBaseURL")
        let origKey   = UserDefaults.standard.string(forKey: "llmAPIKey")
        let origModel = UserDefaults.standard.string(forKey: "llmModel")
        UserDefaults.standard.set(apiBaseURLField.stringValue, forKey: "llmAPIBaseURL")
        UserDefaults.standard.set(apiKeyField.stringValue,     forKey: "llmAPIKey")
        UserDefaults.standard.set(modelField.stringValue,      forKey: "llmModel")
        statusLabel.stringValue = "正在测试..."; statusLabel.textColor = .secondaryLabelColor
        llmRefiner.testConnection { [weak self] success, message in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = success ? "连接成功!" : "连接失败: \(message)"
                self?.statusLabel.textColor = success ? .systemGreen : .systemRed
                if let b = origBase  { UserDefaults.standard.set(b, forKey: "llmAPIBaseURL") }
                if let k = origKey   { UserDefaults.standard.set(k, forKey: "llmAPIKey") }
                if let m = origModel { UserDefaults.standard.set(m, forKey: "llmModel") }
            }
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        UserDefaults.standard.set(apiBaseURLField.stringValue, forKey: "llmAPIBaseURL")
        UserDefaults.standard.set(apiKeyField.stringValue,     forKey: "llmAPIKey")
        UserDefaults.standard.set(modelField.stringValue,      forKey: "llmModel")
        UserDefaults.standard.set(max(0, Double(delayField.stringValue) ?? 0.3), forKey: "llmResultDelay")
        statusLabel.stringValue = "已保存"; statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}
