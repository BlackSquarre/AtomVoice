import Cocoa

// MARK: - 数据模型

struct LLMProvider: Codable {
    var name: String
    var baseURL: String
    var defaultModel: String
}

final class ProviderStore {
    static let key = "llmProviders"

    static var defaults: [LLMProvider] {
        [
            LLMProvider(name: loc("provider.preset.openai"),    baseURL: "https://api.openai.com/v1",                         defaultModel: "gpt-4.1-mini"),
            LLMProvider(name: loc("provider.preset.anthropic"), baseURL: "https://api.anthropic.com/v1",                      defaultModel: "claude-sonnet-4-6"),
            LLMProvider(name: loc("provider.preset.deepseek"),  baseURL: "https://api.deepseek.com/v1",                       defaultModel: "deepseek-v4-flash"),
            LLMProvider(name: loc("provider.preset.moonshot"),  baseURL: "https://api.moonshot.cn/v1",                        defaultModel: "kimi-latest"),
            LLMProvider(name: loc("provider.preset.alibaba"),   baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-turbo-latest"),
            LLMProvider(name: loc("provider.preset.zhipu"),     baseURL: "https://open.bigmodel.cn/api/paas/v4",              defaultModel: "glm-4-flash"),
            LLMProvider(name: loc("provider.preset.lingyi"),    baseURL: "https://api.lingyiwanwu.com/v1",                    defaultModel: "yi-lightning"),
            LLMProvider(name: loc("provider.preset.groq"),      baseURL: "https://api.groq.com/openai/v1",                    defaultModel: "llama-3.3-70b-versatile"),
            LLMProvider(name: loc("provider.preset.ollama"),    baseURL: "http://localhost:11434/v1",                         defaultModel: "qwen2.5:1.5b"),
            LLMProvider(name: loc("provider.preset.custom"),    baseURL: "",                                                  defaultModel: ""),
        ]
    }

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
        sheet.title = loc("provider.title")
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
            ("name", loc("provider.col.name"), 110),
            ("url", loc("provider.col.url"), 250),
            ("model", loc("provider.col.model"), 140)
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

        for (label, field) in [(loc("provider.label.name"), nameField!),
                               (loc("provider.label.url"), urlField!),
                               (loc("provider.label.model"), modelField!)] {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right; l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            grid.addRow(with: [l, field])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 44

        // 完成按钮
        let doneBtn = NSButton(title: loc("provider.done"), target: self, action: #selector(done))
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
        providers.append(LLMProvider(name: loc("provider.new"), baseURL: "", defaultModel: ""))
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("settings.title")
        w.isReleasedWhenClosed = false

        guard let cv = w.contentView else { return }

        let pad: CGFloat = 24
        let labelW: CGFloat = 120
        let gap: CGFloat = 8

        // ── 控件 ─────────────────────────────────────────────
        providers = ProviderStore.load()
        providerPopup = NSPopUpButton()
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providers.forEach { providerPopup.addItem(withTitle: $0.name) }

        let manageBtn = makeButton(loc("settings.manage"), action: #selector(editProviders(_:)))

        apiBaseURLField = makeField(placeholder: "https://api.openai.com/v1")
        apiKeyField     = makeSecureField(placeholder: "sk-...")
        modelField      = makeField(placeholder: "gpt-4o-mini")

        delayPopup = NSPopUpButton()
        for v in delayOptions {
            delayPopup.addItem(withTitle: v == 0 ? loc("settings.delay.immediate") : String(format: "%.1fs", v))
        }

        let promptBtn = makeButton(loc("settings.prompt.edit"), action: #selector(editPrompt(_:)))

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let testBtn   = makeButton(loc("settings.test"),   action: #selector(testConnection(_:)))
        let cancelBtn = makeButton(loc("settings.cancel"), action: #selector(cancelSettings(_:)))
        let saveBtn   = makeButton(loc("settings.save"),   action: #selector(saveSettings(_:)), isPrimary: true)
        saveBtn.keyEquivalent   = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        // ── 说明文字 ──────────────────────────────────────────────
        let descLabel = NSTextField(labelWithString: loc("settings.llm.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── 辅助：构造单行 HStack（左侧固定宽度标签 + 右侧控件） ─
        func makeRow(labelText: String, control: NSView) -> NSView {
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: labelW).isActive = true

            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = gap
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        // 服务商行：popup 自动拉伸，管理按钮紧跟其后
        let providerCtrl = NSStackView(views: [providerPopup, manageBtn])
        providerCtrl.orientation = .horizontal
        providerCtrl.spacing = gap
        providerCtrl.alignment = .centerY

        // 延迟行：popup 固定宽，不拉伸
        let delayWrap = NSStackView(views: [delayPopup])
        delayWrap.orientation = .horizontal
        delayWrap.alignment = .centerY
        delayPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        // ── 表单垂直 StackView ────────────────────────────────
        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false

        let formRows: [(String, NSView)] = [
            (loc("settings.provider"),     providerCtrl),
            (loc("settings.apiUrl"),       apiBaseURLField),
            (loc("settings.apiKey"),       apiKeyField),
            (loc("settings.model"),        modelField),
            (loc("settings.prompt.label"), promptBtn),
            (loc("settings.delay"),        delayWrap),
        ]
        for (text, ctrl) in formRows {
            let row = makeRow(labelText: text, control: ctrl)
            form.addArrangedSubview(row)
        }

        // 分割线
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // 底部：状态标签（左）+ 按钮组（右）
        let bottomRow = NSStackView(views: [statusLabel, testBtn, cancelBtn, saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = gap
        bottomRow.alignment = .centerY
        // 让 statusLabel 撑开左侧空间，按钮靠右
        bottomRow.setCustomSpacing(0, after: statusLabel)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // ── 整体 ─────────────────────────────────────────────
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        [descLabel, form, sep, bottomRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            // root 贴满 contentView（带 padding）
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),

            // 说明文字
            descLabel.topAnchor.constraint(equalTo: root.topAnchor),
            descLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 表单在说明文字下方
            form.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 各行控件拉满 form 宽度（label 固定 + 控件填充剩余）
            // → 由 makeRow 内的 NSStackView 自动处理

            // 分割线
            sep.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 16),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 底部行
            bottomRow.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 16),
            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 让 form 内每行右侧控件自动拉满
        for sub in form.arrangedSubviews {
            sub.trailingAnchor.constraint(equalTo: form.trailingAnchor).isActive = true
        }

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
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = self
        return f
    }

    private func makeSecureField(placeholder: String) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.translatesAutoresizingMaskIntoConstraints = false
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = self
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

        statusLabel.stringValue = loc("settings.testing")
        statusLabel.textColor = .secondaryLabelColor

        llmRefiner.testConnection { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = success ? loc("settings.connected") : loc("settings.connectFailed", msg)
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
        statusLabel.stringValue = loc("settings.saved")
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

extension SettingsWindowController: NSTextFieldDelegate {
    // Enter 键跳到下一个输入框，而不是插入换行
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
