import Cocoa

// MARK: - 服务商编辑器

final class ProviderEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var sheet: NSWindow!
    private var tableView: NSTableView!
    private var nameField: NSTextField!
    private var urlField: NSTextField!
    private var modelField: NSTextField!
    private var providers: [LLMProvider] = []
    var onDone: (([LLMProvider]) -> Void)?

    func show(in parent: NSWindow, onDismiss: (() -> Void)? = nil) {
        providers = ProviderStore.load()
        buildSheet()
        parent.beginSheet(sheet) { _ in onDismiss?() }
    }

    private func buildSheet() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = loc("provider.title")
        WindowConfiguration.configureSheet(sheet, identifier: "AtomVoice.ProviderEditorSheet")
        let cv = sheet.contentView!
        let p: CGFloat = 20

        // 表格（Table view）
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

        // +/- 按钮（+/- buttons）
        let addBtn = NSButton(title: "+", target: self, action: #selector(addRow))
        addBtn.toolTip = loc("tooltip.provider.add")
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .rounded
        cv.addSubview(addBtn)

        let delBtn = NSButton(title: "−", target: self, action: #selector(deleteRow))
        delBtn.toolTip = loc("tooltip.provider.delete")
        delBtn.translatesAutoresizingMaskIntoConstraints = false
        delBtn.bezelStyle = .rounded
        cv.addSubview(delBtn)

        // 编辑区（Edit area）
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

        // 完成按钮（Done button）
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

    func show(in parent: NSWindow, onDismiss: (() -> Void)? = nil) {
        buildSheet()
        parent.beginSheet(sheet) { _ in onDismiss?() }
    }

    private func buildSheet() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = loc("settings.prompt.title")
        WindowConfiguration.configureSheet(sheet, identifier: "AtomVoice.PromptEditorSheet")
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
        // 设置占位标签（Set up placeholder label）
        placeholderLabel = NSTextField(labelWithString: LLMRefiner.currentDefaultSystemPrompt)
        placeholderLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        // 将占位标签直接添加到文本视图（Add placeholder directly to text view）
        textView.addSubview(placeholderLabel)
        
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -4)
        ])

        // 加载自定义提示词（Load custom prompt）
        if !AppSettings.llmSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.string = AppSettings.llmSystemPrompt
        }
        updatePlaceholderVisibility()
        scroll.documentView = textView
        cv.addSubview(scroll)

        let resetBtn = NSButton(title: loc("settings.prompt.reset"), target: self, action: #selector(resetDefault))
        resetBtn.toolTip = loc("tooltip.prompt.reset")
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.bezelStyle = .rounded
        cv.addSubview(resetBtn)

        let doneBtn = NSButton(title: loc("settings.prompt.done"), target: self, action: #selector(done))
        doneBtn.toolTip = loc("tooltip.prompt.done")
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        cv.addSubview(doneBtn)

        let cancelBtn = NSButton(title: loc("settings.prompt.cancel"), target: self, action: #selector(cancel))
        cancelBtn.toolTip = loc("tooltip.prompt.cancel")
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
        AppSettings.llmSystemPrompt = textView.string
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
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var providerPopup: NSPopUpButton!
    private var apiBaseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyReadResult: KeychainStringReadResult = .notFound
    private var modelField: NSTextField!
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
            WindowPresenter.shared.bringToFront(w)
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
        let gap: CGFloat = 8

        // ── 控件 ─────────────────────────────────────────────（Controls）
        providers = ProviderStore.load()
        providerPopup = NSPopUpButton()
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providerPopup.toolTip = loc("tooltip.settings.provider")
        providers.forEach { providerPopup.addItem(withTitle: $0.name) }

        let manageBtn = SettingsUI.makeButton(loc("settings.manage"), target: self, action: #selector(editProviders(_:)))
        manageBtn.toolTip = loc("tooltip.settings.manage")

        apiBaseURLField = SettingsUI.makeField(placeholder: "https://api.openai.com/v1", delegate: self)
        apiBaseURLField.toolTip = loc("tooltip.settings.baseURL")
        apiKeyField     = SettingsUI.makeSecureField(placeholder: "sk-...", delegate: self)
        apiKeyField.toolTip = loc("tooltip.settings.apiKey")
        modelField      = SettingsUI.makeField(placeholder: AppSettings.defaultLLMModel, delegate: self)
        modelField.toolTip = loc("tooltip.settings.model")

        let promptBtn = SettingsUI.makeButton(loc("settings.prompt.edit"), target: self, action: #selector(editPrompt(_:)))
        promptBtn.toolTip = loc("tooltip.settings.prompt")

        statusLabel = SettingsUI.makeSecondaryLabel()

        let testBtn   = SettingsUI.makeButton(loc("settings.test"), target: self, action: #selector(testConnection(_:)))
        testBtn.toolTip = loc("tooltip.settings.test")
        let cancelBtn = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let saveBtn   = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        saveBtn.toolTip = loc("tooltip.settings.save")
        saveBtn.keyEquivalent   = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        // ── 说明文字 ──────────────────────────────────────────────（Description text）
        let descLabel = NSTextField(labelWithString: loc("settings.llm.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── 辅助：构造单行 HStack（左侧固定宽度标签 + 右侧控件） ─（Helper: build single-row HStack with fixed-width label + control）
        // 服务商行：popup 自动拉伸，管理按钮紧跟其后（Provider row: popup auto-stretches, manage button follows）
        let providerCtrl = NSStackView(views: [providerPopup, manageBtn])
        providerCtrl.orientation = .horizontal
        providerCtrl.spacing = gap
        providerCtrl.alignment = .centerY

        // ── 表单垂直 StackView ────────────────────────────────（Form vertical StackView）
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
        ]
        for (text, ctrl) in formRows {
            let row = SettingsUI.makeFormRow(labelText: text, control: ctrl, spacing: gap)
            form.addArrangedSubview(row)
        }

        // 分割线（Separator line）
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // 底部：状态标签（左）+ 按钮组（右）（Bottom: status label (left) + button group (right)）
        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [testBtn, cancelBtn, saveBtn], spacing: gap)

        // ── 整体 ─────────────────────────────────────────────（Overall layout）
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        [descLabel, form, sep, bottomRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            // root 贴满 contentView（带 padding）（Root fills contentView with padding）
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),

            // 说明文字（Description text）
            descLabel.topAnchor.constraint(equalTo: root.topAnchor),
            descLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 表单在说明文字下方（Form below description text）
            form.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 各行控件拉满 form 宽度（label 固定 + 控件填充剩余）（Each row fills form width: label fixed + control fills remaining）
            // → 由 makeRow 内的 NSStackView 自动处理（Handled automatically by NSStackView in makeRow）

            // 分割线（Separator line）
            sep.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 16),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // 底部行（Bottom row）
            bottomRow.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 16),
            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 让 form 内每行右侧控件自动拉满（Let right-side controls in each form row auto-fill width）
        SettingsUI.pinArrangedSubviewsTrailing(in: form)

        self.window = w
        w.delegate = self
        refreshFields()
        let restoredFrame = WindowConfiguration.configureRestorableSettingsWindow(w, identifier: "AtomVoice.SettingsWindow")
        if !restoredFrame {
            w.center()
        }
        WindowPresenter.shared.bringToFront(w)
    }

    // MARK: - Helpers

    // MARK: - State

    private func refreshFields() {
        providers = ProviderStore.load()
        providerPopup?.removeAllItems()
        providers.forEach { providerPopup?.addItem(withTitle: $0.name) }

        apiKeyReadResult = AppSettings.llm.apiKeyReadResult
        let savedURL = AppSettings.llmAPIBaseURL
        let matchIdx = providers.firstIndex { $0.baseURL == savedURL } ?? (providers.count - 1)
        providerPopup?.selectItem(at: matchIdx)

        apiBaseURLField?.stringValue = savedURL
        apiKeyField?.stringValue = apiKeyReadResult.string ?? ""
        modelField?.stringValue = AppSettings.llmModel
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
        editor.onDone = { [weak self] _ in
            guard let self else { return }
            // 服务商列表更新不覆盖连接表单的未保存内容。
            self.providers = ProviderStore.load()
            self.providerPopup.removeAllItems()
            self.providers.forEach { self.providerPopup.addItem(withTitle: $0.name) }
            if let index = self.providers.firstIndex(where: { $0.baseURL == self.apiBaseURLField.stringValue }) {
                self.providerPopup.selectItem(at: index)
            }
        }
        providerEditor = editor
        editor.show(in: w) { [weak self] in
            // sheet 关闭后立即释放 editor 实例，回收内存
            // (Release editor instance right after the sheet closes to reclaim memory.)
            self?.providerEditor = nil
        }
    }

    @objc private func editPrompt(_ sender: NSButton) {
        guard let w = window else { return }
        let editor = PromptEditorController()
        promptEditor = editor
        editor.show(in: w) { [weak self] in
            self?.promptEditor = nil
        }
    }

    @objc private func testConnection(_ sender: NSButton) {
        if case .failure = apiKeyReadResult, apiKeyField.stringValue.isEmpty {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            return
        }
        let testConnection = LLMConnectionSettings(
            baseURL: apiBaseURLField.stringValue,
            apiKey: apiKeyField.stringValue,
            model: modelField.stringValue
        )
        statusLabel.stringValue = loc("settings.testing")
        statusLabel.textColor = .secondaryLabelColor

        // 测试仅使用当前表单，不临时覆写钥匙串，也不在异步完成后恢复旧空值。
        llmRefiner.testConnection(connection: testConnection) { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = success ? loc("settings.connected") : loc("settings.connectFailed", msg)
                self?.statusLabel.textColor = success ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        let connection = LLMConnectionSettings(
            baseURL: apiBaseURLField.stringValue,
            apiKey: apiKeyField.stringValue,
            model: modelField.stringValue
        )
        guard AppSettings.saveLLMConnection(connection, previousKeyRead: apiKeyReadResult) else {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            return
        }
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
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    // Enter 键跳到下一个输入框，而不是插入换行（Enter key jumps to next field instead of inserting newline）
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
