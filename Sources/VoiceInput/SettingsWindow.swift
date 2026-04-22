import Cocoa

// MARK: - 数据模型

struct LLMProvider: Codable {
    var name: String
    var baseURL: String
    var defaultModel: String
}

final class ProviderStore {
    static let key = "llmProviders"

    static let defaults: [LLMProvider] = [
        LLMProvider(name: "OpenAI",            baseURL: "https://api.openai.com/v1",                           defaultModel: "gpt-4o-mini"),
        LLMProvider(name: "DeepSeek",          baseURL: "https://api.deepseek.com/v1",                         defaultModel: "deepseek-chat"),
        LLMProvider(name: "Moonshot (Kimi)",   baseURL: "https://api.moonshot.cn/v1",                          defaultModel: "moonshot-v1-8k"),
        LLMProvider(name: "阿里云百炼 (Qwen)", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",   defaultModel: "qwen-turbo"),
        LLMProvider(name: "智谱 AI (GLM)",     baseURL: "https://open.bigmodel.cn/api/paas/v4",                defaultModel: "glm-4-flash"),
        LLMProvider(name: "零一万物 (Yi)",     baseURL: "https://api.lingyiwanwu.com/v1",                      defaultModel: "yi-lightning"),
        LLMProvider(name: "Groq",              baseURL: "https://api.groq.com/openai/v1",                      defaultModel: "llama-3.3-70b-versatile"),
        LLMProvider(name: "Ollama (本地)",     baseURL: "http://localhost:11434/v1",                           defaultModel: "qwen2.5:1.5b"),
        LLMProvider(name: "自定义",            baseURL: "",                                                    defaultModel: ""),
    ]

    static func load() -> [LLMProvider] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LLMProvider].self, from: data)
        else { return defaults }
        return list
    }

    static func save(_ list: [LLMProvider]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 服务商编辑器

final class ProviderEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var sheet: NSWindow!
    private var tableView: NSTableView!
    private var nameField: NSTextField!
    private var urlField: NSTextField!
    private var modelField: NSTextField!
    private var providers: [LLMProvider] = []
    var onDone: (([LLMProvider]) -> Void)?

    func show(in parent: NSWindow) {
        providers = ProviderStore.load()
        buildSheet()
        parent.beginSheet(sheet, completionHandler: nil)
    }

    private func buildSheet() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "管理服务商"
        let cv = sheet.contentView!
        let p: CGFloat = 20

        // 表格
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        cv.addSubview(scroll)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false

        let cols: [(String, String, CGFloat)] = [
            ("name", "名称", 110), ("url", "API 地址", 250), ("model", "默认模型", 140)
        ]
        for (id, title, w) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = w; col.isEditable = true
            tableView.addTableColumn(col)
        }
        scroll.documentView = tableView

        // +/- 按钮
        let addBtn = NSButton(title: "+", target: self, action: #selector(addRow))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .rounded
        cv.addSubview(addBtn)

        let delBtn = NSButton(title: "−", target: self, action: #selector(deleteRow))
        delBtn.translatesAutoresizingMaskIntoConstraints = false
        delBtn.bezelStyle = .rounded
        cv.addSubview(delBtn)

        // 编辑区
        let sep = NSBox()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.boxType = .separator
        cv.addSubview(sep)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        cv.addSubview(grid)

        nameField  = makeField(); urlField = makeField(); modelField = makeField()
        nameField.delegate = self; urlField.delegate = self; modelField.delegate = self

        for (label, field) in [("名称:", nameField!), ("地址:", urlField!), ("模型:", modelField!)] {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right; l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            grid.addRow(with: [l, field])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 44

        // 完成按钮
        let doneBtn = NSButton(title: "完成", target: self, action: #selector(done))
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: cv.topAnchor, constant: p),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),
            scroll.heightAnchor.constraint(equalToConstant: 200),

            addBtn.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            addBtn.widthAnchor.constraint(equalToConstant: 28),

            delBtn.topAnchor.constraint(equalTo: addBtn.topAnchor),
            delBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 4),
            delBtn.widthAnchor.constraint(equalToConstant: 28),

            sep.topAnchor.constraint(equalTo: addBtn.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),
            sep.heightAnchor.constraint(equalToConstant: 1),

            grid.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),

            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -p),
            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),
            doneBtn.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    private func makeField() -> NSTextField {
        let f = NSTextField()
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 12)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return f
    }

    // MARK: Table DataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    func tableView(_ tableView: NSTableView, objectValueFor col: NSTableColumn?, row: Int) -> Any? {
        let p = providers[row]
        switch col?.identifier.rawValue {
        case "name":  return p.name
        case "url":   return p.baseURL
        case "model": return p.defaultModel
        default:      return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue obj: Any?, for col: NSTableColumn?, row: Int) {
        guard let v = obj as? String else { return }
        switch col?.identifier.rawValue {
        case "name":  providers[row].name = v
        case "url":   providers[row].baseURL = v
        case "model": providers[row].defaultModel = v
        default: break
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        nameField.stringValue  = providers[row].name
        urlField.stringValue   = providers[row].baseURL
        modelField.stringValue = providers[row].defaultModel
    }

    // MARK: NSTextFieldDelegate — 实时同步到 providers 数组

    func controlTextDidChange(_ obj: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        providers[row].name         = nameField.stringValue
        providers[row].baseURL      = urlField.stringValue
        providers[row].defaultModel = modelField.stringValue
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(0..<3))
    }

    // MARK: Actions

    @objc private func addRow() {
        providers.append(LLMProvider(name: "新服务商", baseURL: "", defaultModel: ""))
        tableView.reloadData()
        let i = providers.count - 1
        tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        tableView.scrollRowToVisible(i)
        nameField.stringValue = providers[i].name
        urlField.stringValue = ""; modelField.stringValue = ""
        sheet.makeFirstResponder(nameField)
    }

    @objc private func deleteRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        providers.remove(at: row)
        tableView.reloadData()
        if !providers.isEmpty {
            let next = min(row, providers.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
    }

    @objc private func done() {
        ProviderStore.save(providers)
        onDone?(providers)
        sheet.sheetParent?.endSheet(sheet)
    }
}

// MARK: - 提示词编辑器

final class PromptEditorController: NSObject, NSTextViewDelegate {
    private var sheet: NSWindow!
    private var textView: NSTextView!
    private var placeholderLabel: NSTextField!
    var onDone: (() -> Void)?

    func show(in parent: NSWindow) {
        buildSheet()
        parent.beginSheet(sheet, completionHandler: nil)
    }

    private func buildSheet() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = loc("settings.prompt.title")
        let cv = sheet.contentView!
        let p: CGFloat = 20

        let desc = NSTextField(labelWithString: loc("settings.prompt.desc"))
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byWordWrapping
        desc.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(desc)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        
        textView = NSTextView()
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        // Set up placeholder label
        placeholderLabel = NSTextField(labelWithString: LLMRefiner.currentDefaultSystemPrompt)
        placeholderLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        // Add placeholder directly to text view
        textView.addSubview(placeholderLabel)
        
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -4)
        ])

        // Load custom prompt
        if let custom = UserDefaults.standard.string(forKey: "llmSystemPrompt"), !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.string = custom
        }
        updatePlaceholderVisibility()
        scroll.documentView = textView
        cv.addSubview(scroll)

        let resetBtn = NSButton(title: loc("settings.prompt.reset"), target: self, action: #selector(resetDefault))
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.bezelStyle = .rounded
        cv.addSubview(resetBtn)

        let doneBtn = NSButton(title: loc("settings.prompt.done"), target: self, action: #selector(done))
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)

        let cancelBtn = NSButton(title: loc("settings.prompt.cancel"), target: self, action: #selector(cancel))
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cv.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            desc.topAnchor.constraint(equalTo: cv.topAnchor, constant: p),
            desc.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            desc.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),

            scroll.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),
            scroll.bottomAnchor.constraint(equalTo: doneBtn.topAnchor, constant: -p),

            resetBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: p),
            resetBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -p),

            doneBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -p),
            doneBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -p),

            cancelBtn.trailingAnchor.constraint(equalTo: doneBtn.leadingAnchor, constant: -8),
            cancelBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -p),
        ])
    }

    @objc private func resetDefault() {
        textView.string = ""
        updatePlaceholderVisibility()
    }

    @objc private func cancel() {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func done() {
        UserDefaults.standard.set(textView.string, forKey: "llmSystemPrompt")
        onDone?()
        sheet.sheetParent?.endSheet(sheet)
    }

    // MARK: NSTextViewDelegate
    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }
}

// MARK: - 设置窗口

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var providerPopup: NSPopUpButton!
    private var apiBaseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var delayPopup: NSPopUpButton!
    private let delayOptions: [Double] = [0, 0.5, 1.0, 1.5, 2.0]
    private var statusLabel: NSTextField!
    private let llmRefiner: LLMRefiner
    private var providerEditor: ProviderEditorController?
    private var promptEditor: PromptEditorController?
    private var providers: [LLMProvider] = []

    init(llmRefiner: LLMRefiner) {
        self.llmRefiner = llmRefiner
    }

    func showWindow() {
        if let w = window {
            refreshFields()
            AppDelegate.bringToFront(w)
            return
        }
        buildWindow()
    }

    // MARK: - 构建窗口

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("settings.title")
        w.isReleasedWhenClosed = false

        // ── 直接使用系统 contentView，不替换它 ──────────────
        guard let cv = w.contentView else { return }

        // 主垂直 StackView
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            vStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            vStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            vStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])

        // ── 表单区（NSGridView） ──────────────────────────────
        let formGrid = NSGridView()
        formGrid.rowSpacing = 10
        formGrid.columnSpacing = 8
        formGrid.translatesAutoresizingMaskIntoConstraints = false

        // 服务商行 = popup + 管理按钮
        providers = ProviderStore.load()
        providerPopup = NSPopUpButton()
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providers.forEach { providerPopup.addItem(withTitle: $0.name) }

        let manageBtn = NSButton(title: "管理...", target: self, action: #selector(editProviders(_:)))
        manageBtn.bezelStyle = .rounded

        let providerRow = NSStackView(views: [providerPopup, manageBtn])
        providerRow.orientation = .horizontal
        providerRow.spacing = 8

        apiBaseURLField = makeField(placeholder: "https://api.openai.com/v1")
        apiKeyField = makeSecureField(placeholder: "sk-...")
        modelField  = makeField(placeholder: "gpt-4o-mini")

        // 延迟行 = 下拉选项
        delayPopup = NSPopUpButton()
        delayPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in delayOptions {
            let title = v == 0 ? loc("settings.delay.immediate") : String(format: "%.1fs", v)
            delayPopup.addItem(withTitle: title)
        }
        delayPopup.widthAnchor.constraint(equalToConstant: 100).isActive = true

        // 提示词
        let promptBtn = makeButton(loc("settings.prompt.edit"), action: #selector(editPrompt(_:)))

        let rows: [(String, NSView)] = [
            ("服务商:", providerRow),
            ("API 地址:", apiBaseURLField),
            ("API 密钥:", apiKeyField),
            ("模型:", modelField),
            (loc("settings.prompt.label"), promptBtn),
            ("结果展示延迟:", delayPopup),
        ]
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            formGrid.addRow(with: [label, control])
        }
        // 标签列右对齐、固定宽度
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.column(at: 0).width = 96
        // 控件列拉伸填满
        formGrid.column(at: 1).xPlacement = .fill

        vStack.addArrangedSubview(formGrid)
        formGrid.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true

        // ── 分割线 ────────────────────────────────────────────
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        vStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        vStack.setCustomSpacing(16, after: formGrid)
        vStack.setCustomSpacing(16, after: sep)

        // ── 底部行：状态 + 按钮 ───────────────────────────────
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let testBtn   = makeButton("测试连接", action: #selector(testConnection(_:)))
        let cancelBtn = makeButton("取消",     action: #selector(cancelSettings(_:)))
        let saveBtn   = makeButton("保存",     action: #selector(saveSettings(_:)), isPrimary: true)
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = NSStackView(views: [statusLabel, testBtn, cancelBtn, saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        vStack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true

        self.window = w
        w.delegate = self
        refreshFields()
        w.center()
        w.recalculateKeyViewLoop()
        AppDelegate.bringToFront(w)
    }

    // MARK: - Helpers

    private func makeField(placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func makeSecureField(placeholder: String) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func makeButton(_ title: String, action: Selector, isPrimary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        if #available(macOS 26.0, *) { b.bezelStyle = .glass }
        else { b.bezelStyle = .rounded }
        return b
    }

    // MARK: - State

    private func refreshFields() {
        providers = ProviderStore.load()
        providerPopup?.removeAllItems()
        providers.forEach { providerPopup?.addItem(withTitle: $0.name) }

        let savedURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let matchIdx = providers.firstIndex { $0.baseURL == savedURL } ?? (providers.count - 1)
        providerPopup?.selectItem(at: matchIdx)

        apiBaseURLField?.stringValue = savedURL
        apiKeyField?.stringValue     = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        modelField?.stringValue      = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"
        let delay = UserDefaults.standard.double(forKey: "llmResultDelay")
        // 选中最近的选项
        let closestIdx = delayOptions.enumerated().min(by: { abs($0.element - delay) < abs($1.element - delay) })?.offset ?? 1
        delayPopup?.selectItem(at: closestIdx)
        statusLabel?.stringValue     = ""
    }

    // MARK: - Actions

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let p = providers[sender.indexOfSelectedItem]
        if p.baseURL.isEmpty {
            apiBaseURLField.stringValue = ""
            modelField.stringValue = ""
            window?.makeFirstResponder(apiBaseURLField)
        } else {
            apiBaseURLField.stringValue = p.baseURL
            modelField.stringValue = p.defaultModel
        }
    }

    @objc private func editProviders(_ sender: NSButton) {
        guard let w = window else { return }
        let editor = ProviderEditorController()
        editor.onDone = { [weak self] _ in self?.refreshFields() }
        providerEditor = editor
        editor.show(in: w)
    }

    @objc private func editPrompt(_ sender: NSButton) {
        guard let w = window else { return }
        let editor = PromptEditorController()
        promptEditor = editor
        editor.show(in: w)
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

        llmRefiner.testConnection { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = success ? "连接成功!" : "连接失败: \(msg)"
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
        let selectedDelay = delayOptions[delayPopup.indexOfSelectedItem]
        UserDefaults.standard.set(selectedDelay, forKey: "llmResultDelay")
        statusLabel.stringValue = "已保存"
        statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            AppDelegate.resetActivationIfNeeded(closing: w)
        }
    }
}
