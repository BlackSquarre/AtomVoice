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
        guard providers.indices.contains(row) else { return nil }
        let p = providers[row]
        switch col?.identifier.rawValue {
        case "name":  return p.name
        case "url":   return p.baseURL
        case "model": return p.defaultModel
        default:      return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue obj: Any?, for col: NSTableColumn?, row: Int) {
        guard providers.indices.contains(row), let v = obj as? String else { return }
        switch col?.identifier.rawValue {
        case "name":  providers[row].name = v
        case "url":   providers[row].baseURL = v
        case "model": providers[row].defaultModel = v
        default: break
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard providers.indices.contains(row) else { return }
        nameField.stringValue  = providers[row].name
        urlField.stringValue   = providers[row].baseURL
        modelField.stringValue = providers[row].defaultModel
    }

    // MARK: NSTextFieldDelegate — 实时同步到 providers 数组

    func controlTextDidChange(_ obj: Notification) {
        let row = tableView.selectedRow
        guard providers.indices.contains(row) else { return }
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
        guard providers.indices.contains(row) else { return }
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
    private var contentView: NSStackView?
    private var descriptionLabel: NSTextField?
    private var promptFormRow: NSView?
    private var providerFormRow: NSView?
    private weak var cancelControl: NSButton?
    private weak var saveControl: NSButton?
    private var providerPopup: NSPopUpButton!
    private var apiBaseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyReadResult: KeychainStringReadResult = .notFound
    private var modelField: NSTextField!
    private var statusLabel: NSTextField!
    private let llmRefiner: LLMRefiner
    private let allowsSideEffects: Bool
    private var providerEditor: ProviderEditorController?
    private var promptEditor: PromptEditorController?
    private var providers: [LLMProvider] = []
    private var baselineConnection: LLMConnectionSettings?
    private var parentWindowProvider: (() -> NSWindow?)?
    private var onEmbeddedSizeChanged: (() -> Void)?
    private var onEmbeddedSaved: (() -> Void)?
    private var isEmbedded = false
    private var embeddedProvider: RefinementProvider?
    private var requiresNewProviderKey = false
    private var connectionTestGeneration = 0
    private let credentialQueue = DispatchQueue(label: "AtomVoice.LLMSettings.credentials", qos: .userInitiated)
    private var credentialGeneration = 0
    private(set) var isLoadingCredentials = false
    private(set) var isSavingCredentials = false
    private var credentialControls: [NSControl] = []
    private var credentialActionControls: [NSControl] = []
    private let connectionSettings: LLMSettings

    init(llmRefiner: LLMRefiner, allowsSideEffects: Bool = true, connectionSettings: LLMSettings = AppSettings.llm) {
        self.llmRefiner = llmRefiner
        self.allowsSideEffects = allowsSideEffects
        self.connectionSettings = connectionSettings
    }

    /// 嵌入同一份表单，不创建窗口或触发激活；重复进入保留现有草稿。
    func makeEmbeddedView(provider: RefinementProvider? = nil,
                          parentWindow: @escaping () -> NSWindow?,
                          onSizeChanged: @escaping () -> Void,
                          onSaved: @escaping () -> Void) -> NSView {
        let hadContent = contentView != nil
        let previousProviderURL = embeddedProvider?.baseURL
        isEmbedded = true
        embeddedProvider = provider
        parentWindowProvider = parentWindow
        onEmbeddedSizeChanged = onSizeChanged
        onEmbeddedSaved = onSaved
        let view = makeContentView()
        if hadContent, previousProviderURL != provider?.baseURL { refreshFields() }
        updatePresentation()
        DispatchQueue.main.async { [weak self] in self?.notifySizeChanged() }
        return view
    }

    /// 只刷新服务商元数据，不重新读取密钥或覆盖尚未保存的连接。
    func refreshEmbeddedStatus() {
        guard contentView != nil else { return }
        reloadProviders(preservingDraft: true)
        notifySizeChanged()
    }

    func discardEmbeddedChanges() {
        guard contentView != nil else { return }
        guard !isSavingCredentials else { return }
        refreshFields()
        notifySizeChanged()
    }

    var hasEmbeddedChanges: Bool {
        guard let baselineConnection, let connection = formConnection else { return false }
        return connection.baseURL != baselineConnection.baseURL ||
            connection.apiKey != baselineConnection.apiKey ||
            connection.model != baselineConnection.model
    }

    /// 供应商快捷选择只修改连接草稿，不提交密钥或其它设置。
    func selectEmbeddedProvider(named name: String) {
        guard embeddedProvider == nil else { return }
        _ = makeContentView()
        guard let index = providers.firstIndex(where: { $0.name == name }) else { return }
        providerPopup.selectItem(at: index)
        providerChanged(providerPopup)
    }

    /// 复用已加载表单判断当前供应商，侧栏查询不再次访问 Keychain。
    var embeddedProviderName: String? {
        guard let connection = formConnection,
              !connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let embeddedProvider {
            return embeddedProvider.matches(baseURL: connection.baseURL) ? loc(embeddedProvider.nameKey) : nil
        }
        let name = providers.first(where: {
            !$0.baseURL.isEmpty && $0.baseURL == connection.baseURL
        })?.name ?? loc("provider.preset.custom")
        return name.isEmpty ? loc("provider.preset.custom") : name
    }

    func showWindow() {
        let wasFixedProvider = embeddedProvider != nil
        isEmbedded = false
        embeddedProvider = nil
        onEmbeddedSizeChanged = nil
        onEmbeddedSaved = nil
        parentWindowProvider = { [weak self] in self?.window }
        if wasFixedProvider, contentView != nil { refreshFields() }
        if let window {
            installContent(in: window)
            WindowPresenter.shared.bringToFront(window)
        } else {
            buildWindow()
        }
    }

    // MARK: - 表单与窗口

    private var presentationWindow: NSWindow? { parentWindowProvider?() ?? window }

    private var formConnection: LLMConnectionSettings? {
        guard let apiBaseURLField, let apiKeyField, let modelField else { return nil }
        return LLMConnectionSettings(baseURL: apiBaseURLField.stringValue,
                                     apiKey: apiKeyField.stringValue,
                                     model: modelField.stringValue)
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("settings.title")
        w.isReleasedWhenClosed = false
        window = w
        w.delegate = self
        installContent(in: w)
        let restoredFrame = WindowConfiguration.configureRestorableSettingsWindow(w, identifier: "AtomVoice.SettingsWindow")
        if !restoredFrame { w.center() }
        WindowPresenter.shared.bringToFront(w)
    }

    private func installContent(in window: NSWindow) {
        guard let host = window.contentView else { return }
        let view = makeContentView()
        updatePresentation()
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -24),
        ])
    }

    private func makeContentView() -> NSView {
        if let contentView { return contentView }
        let gap: CGFloat = 8

        providerPopup = NSPopUpButton()
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        providerPopup.toolTip = loc("tooltip.settings.provider")

        let manageBtn = SettingsUI.makeButton(loc("settings.manage"), target: self, action: #selector(editProviders(_:)))
        manageBtn.toolTip = loc("tooltip.settings.manage")
        manageBtn.isEnabled = allowsSideEffects
        apiBaseURLField = SettingsUI.makeField(placeholder: "https://api.openai.com/v1", delegate: self)
        apiBaseURLField.identifier = NSUserInterfaceItemIdentifier("llm.apiBaseURL")
        apiBaseURLField.toolTip = loc("tooltip.settings.baseURL")
        apiKeyField = SettingsUI.makeSecureField(placeholder: "sk-...", delegate: self)
        apiKeyField.identifier = NSUserInterfaceItemIdentifier("llm.apiKey")
        apiKeyField.toolTip = loc("tooltip.settings.apiKey")
        modelField = SettingsUI.makeField(placeholder: AppSettings.defaultLLMModel, delegate: self)
        modelField.identifier = NSUserInterfaceItemIdentifier("llm.model")
        modelField.toolTip = loc("tooltip.settings.model")

        let promptBtn = SettingsUI.makeButton(loc("settings.prompt.edit"), target: self, action: #selector(editPrompt(_:)))
        promptBtn.toolTip = loc("tooltip.settings.prompt")
        promptBtn.isEnabled = allowsSideEffects
        statusLabel = SettingsUI.makeSecondaryLabel()
        SettingsUI.allowHorizontalWrapping(statusLabel, preferredMaxLayoutWidth: 320)

        let testBtn = SettingsUI.makeButton(loc("settings.test"), target: self, action: #selector(testConnection(_:)))
        testBtn.toolTip = loc("tooltip.settings.test")
        testBtn.isEnabled = allowsSideEffects
        let cancelBtn = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let saveBtn = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        cancelControl = cancelBtn
        saveControl = saveBtn
        saveBtn.toolTip = loc("tooltip.settings.save")
        saveBtn.isEnabled = allowsSideEffects
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let descLabel = NSTextField(labelWithString: loc("settings.llm.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        SettingsUI.allowHorizontalWrapping(descLabel, preferredMaxLayoutWidth: 512)
        descriptionLabel = descLabel

        let providerCtrl = NSStackView(views: [providerPopup, manageBtn])
        providerCtrl.orientation = .horizontal
        providerCtrl.spacing = gap
        providerCtrl.alignment = .centerY
        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false
        let formRows: [(String, NSView)] = [
            (loc("settings.provider"), providerCtrl),
            (loc("settings.apiUrl"), apiBaseURLField),
            (loc("settings.apiKey"), apiKeyField),
            (loc("settings.model"), modelField),
            (loc("settings.prompt.label"), promptBtn),
        ]
        for (index, entry) in formRows.enumerated() {
            let row = SettingsUI.makeFormRow(labelText: entry.0, control: entry.1, spacing: gap)
            form.addArrangedSubview(row)
            if index == 0 {
                row.identifier = NSUserInterfaceItemIdentifier("llm.provider")
                providerFormRow = row
            }
            if index == formRows.count - 1 { promptFormRow = row }
        }
        SettingsUI.pinArrangedSubviewsTrailing(in: form)

        let separator = NSBox()
        separator.boxType = .separator
        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [testBtn, cancelBtn, saveBtn], spacing: gap)
        let root = NSStackView(views: [descLabel, form, separator, bottomRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        SettingsUI.pinArrangedSubviewsTrailing(in: root)
        contentView = root
        credentialControls = [providerPopup, manageBtn, apiBaseURLField, apiKeyField, modelField, testBtn, saveBtn, cancelBtn]
        credentialActionControls = [manageBtn, testBtn, saveBtn]
        refreshFields()
        updatePresentation()
        return root
    }

    private func updatePresentation() {
        descriptionLabel?.isHidden = isEmbedded
        promptFormRow?.isHidden = isEmbedded
        providerFormRow?.isHidden = embeddedProvider != nil
        apiBaseURLField?.isEditable = embeddedProvider == nil && !isLoadingCredentials && !isSavingCredentials
        apiBaseURLField?.isSelectable = true
        cancelControl?.title = isEmbedded ? loc("preferences.discard") : loc("settings.cancel")
        saveControl?.toolTip = isEmbedded ? nil : loc("tooltip.settings.save")
    }

    private func notifySizeChanged() {
        contentView?.invalidateIntrinsicContentSize()
        onEmbeddedSizeChanged?()
    }

    // MARK: - 草稿与操作

    private func reloadProviders(preservingDraft: Bool) {
        providers = allowsSideEffects ? ProviderStore.load() : ProviderStore.defaults
        providerPopup.removeAllItems()
        providers.forEach { providerPopup.addItem(withTitle: $0.name) }
        let url = preservingDraft ? apiBaseURLField.stringValue : baselineConnection?.baseURL
        if let index = providers.firstIndex(where: { $0.baseURL == url }) {
            providerPopup.selectItem(at: index)
        } else if let customIndex = providers.firstIndex(where: { $0.baseURL.isEmpty }) {
            providerPopup.selectItem(at: customIndex)
        } else {
            providerPopup.select(nil)
        }
    }

    private func refreshFields() {
        guard !isSavingCredentials else { return }
        connectionTestGeneration += 1
        credentialGeneration += 1
        let generation = credentialGeneration
        requiresNewProviderKey = false
        // 静态预览与切换供应商不读取无关旧密钥。
        let savedURL = allowsSideEffects ? connectionSettings.apiBaseURL : AppSettings.defaultLLMBaseURL
        if !allowsSideEffects || (embeddedProvider.map { !$0.matches(baseURL: savedURL) } ?? false) {
            isLoadingCredentials = false
            requiresNewProviderKey = allowsSideEffects && embeddedProvider != nil
            applyConnection(.init(baseURL: embeddedProvider?.baseURL ?? AppSettings.defaultLLMBaseURL,
                                  apiKey: "", model: embeddedProvider?.model ?? AppSettings.defaultLLMModel), keyRead: .notFound)
            return
        }
        isLoadingCredentials = true
        updateCredentialControls()
        statusLabel.stringValue = loc("settings.loading")
        let settings = connectionSettings
        credentialQueue.async { [weak self] in
            let result = settings.readConnection()
            DispatchQueue.main.async {
                guard let self, self.credentialGeneration == generation else { return }
                self.isLoadingCredentials = false
                self.applyConnection(result.0, keyRead: result.1)
            }
        }
    }

    private func applyConnection(_ connection: LLMConnectionSettings, keyRead: KeychainStringReadResult) {
        apiKeyReadResult = keyRead
        baselineConnection = connection
        apiBaseURLField.stringValue = connection.baseURL
        apiKeyField.stringValue = connection.apiKey
        modelField.stringValue = connection.model
        reloadProviders(preservingDraft: false)
        if case .failure = keyRead {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = .secondaryLabelColor
        }
        updateCredentialControls()
        notifySizeChanged()
    }

    private func updateCredentialControls() {
        let enabled = !isLoadingCredentials && !isSavingCredentials
        credentialControls.forEach { $0.isEnabled = enabled }
        credentialActionControls.forEach { $0.isEnabled = enabled && allowsSideEffects }
        updatePresentation()
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard embeddedProvider == nil else { return }
        guard providers.indices.contains(sender.indexOfSelectedItem) else { return }
        let provider = providers[sender.indexOfSelectedItem]
        apiBaseURLField.stringValue = provider.baseURL
        modelField.stringValue = provider.defaultModel
        if provider.baseURL.isEmpty { presentationWindow?.makeFirstResponder(apiBaseURLField) }
        connectionDraftChanged()
    }

    @objc private func editProviders(_ sender: NSButton) {
        guard embeddedProvider == nil, allowsSideEffects, let parent = presentationWindow else { return }
        let editor = ProviderEditorController()
        editor.onDone = { [weak self] _ in
            guard let self else { return }
            // 更新模板列表不覆盖当前连接草稿。
            self.reloadProviders(preservingDraft: true)
            self.notifySizeChanged()
        }
        providerEditor = editor
        editor.show(in: parent) { [weak self] in self?.providerEditor = nil }
    }

    @objc private func editPrompt(_ sender: NSButton) {
        guard allowsSideEffects, let parent = presentationWindow else { return }
        let editor = PromptEditorController()
        promptEditor = editor
        editor.show(in: parent) { [weak self] in self?.promptEditor = nil }
    }

    @objc private func testConnection(_ sender: NSButton) {
        guard allowsSideEffects, !isLoadingCredentials, !isSavingCredentials, let connection = formConnection else { return }
        connectionTestGeneration += 1
        let generation = connectionTestGeneration
        guard validateFixedProviderDraft(connection) else { return }
        if case .failure = apiKeyReadResult, connection.apiKey.isEmpty {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            notifySizeChanged()
            return
        }
        statusLabel.stringValue = loc("settings.testing")
        statusLabel.textColor = .secondaryLabelColor
        notifySizeChanged()
        // 测试只使用当前表单，不写配置或临时覆盖钥匙串。
        llmRefiner.testConnection(connection: connection) { [weak self] success, message in
            DispatchQueue.main.async {
                guard let self, self.connectionTestGeneration == generation else { return }
                self.statusLabel.stringValue = success ? loc("settings.connected") : loc("settings.connectFailed", message)
                self.statusLabel.textColor = success ? .systemGreen : .systemRed
                self.notifySizeChanged()
            }
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        guard allowsSideEffects, !isLoadingCredentials, !isSavingCredentials, let connection = formConnection else { return }
        guard validateFixedProviderDraft(connection) else { return }
        isSavingCredentials = true
        connectionTestGeneration += 1
        updateCredentialControls()
        statusLabel.stringValue = loc("settings.saving")
        statusLabel.textColor = .secondaryLabelColor
        notifySizeChanged()
        let settings = connectionSettings, previousKeyRead = apiKeyReadResult
        credentialQueue.async { [self] in
            let saved = settings.saveConnection(connection, previousKeyRead: previousKeyRead)
            DispatchQueue.main.async {
                self.isSavingCredentials = false
                self.updateCredentialControls()
                guard saved else {
                    self.statusLabel.stringValue = loc("doubao.settings.keychainFailed")
                    self.statusLabel.textColor = .systemRed
                    self.notifySizeChanged()
                    return
                }
                self.baselineConnection = connection
                self.requiresNewProviderKey = false
                self.apiKeyReadResult = connection.apiKey.isEmpty ? .notFound : .value(connection.apiKey)
                self.statusLabel.stringValue = loc("settings.saved")
                self.statusLabel.textColor = .systemGreen
                if self.isEmbedded { self.notifySizeChanged(); self.onEmbeddedSaved?() }
                else { self.window?.close() }
            }
        }
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        if isEmbedded { discardEmbeddedChanges() }
        else { window?.close() }
    }

    private func validateFixedProviderDraft(_ connection: LLMConnectionSettings) -> Bool {
        let errorKey: String?
        if let embeddedProvider, !embeddedProvider.matches(baseURL: connection.baseURL) {
            errorKey = "error.invalidUrl"
        } else if requiresNewProviderKey, connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 空草稿不能提交新 URL 却继续沿用全局单一槽中的旧供应商密钥。
            errorKey = "error.noApiKey"
        } else {
            errorKey = nil
        }
        guard let errorKey else { return true }
        statusLabel.stringValue = loc(errorKey)
        statusLabel.textColor = .systemRed
        notifySizeChanged()
        return false
    }

    private func connectionDraftChanged() {
        connectionTestGeneration += 1
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        notifySizeChanged()
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
    func controlTextDidChange(_ notification: Notification) {
        connectionDraftChanged()
    }

    // Enter 键跳到下一个输入框，而不是插入换行（Enter key jumps to next field instead of inserting newline）
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
