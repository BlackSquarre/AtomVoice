import Cocoa

final class OpenAISettingsTab: NSObject, ASRSettingsTab, NSTextViewDelegate {
    let identifier = OpenAIASRSettings.engineCode
    let label = loc("asrSettings.tab.openai")
    private let editor: OpenAIASRSettingsEditor
    private weak var textFieldDelegate: NSTextFieldDelegate?
    private var keyField: NSSecureTextField!
    private var languageField: NSTextField!
    private var promptView: NSTextView!
    private var keywordsView: NSTextView!
    private var statusLabel: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var modelStatusLabel: NSTextField!
    private var modelRefreshButton: NSButton!
    private var delayPopup: NSPopUpButton!
    private var hintsLabel: NSTextField!
    private let loadModels: (String) async throws -> [OpenAIASRModel]
    private let localize: (String) -> String
    private var modelTask: Task<Void, Never>?
    private var availableModels: [OpenAIASRModel]?
    private var hasActivatedModels = false
    private let delayValues = ["minimal", "low", "medium", "high", "xhigh"]
    private var clearKey = false
    private let allowsExternalActions: Bool
    private var cachedView: NSView?
    private var cachedHintsView: NSView?
    private var separatePromptView: NSTextView?
    private var separateKeywordsView: NSTextView?
    private var allowsModelFetch = true
    private var includesContextInConnection = true
    private let usesAsyncCredentials: Bool
    private var removeKeyButton: NSButton?
    private var activateModelsAfterLoad = false
    private(set) var isLoadingCredentials = false
    private(set) var isSavingCredentials = false
    var isBusy: Bool { isLoadingCredentials || isSavingCredentials }
    var onBusyChanged: (() -> Void)?
    var onOperationCompleted: ((String, ASRSettingsTabSaveOutcome) -> Void)?
    var onContentSizeChanged: (() -> Void)?

    var supportsContextHints: Bool { selectedModel.supportsContext }

    init(textFieldDelegate: NSTextFieldDelegate?, editor: OpenAIASRSettingsEditor = .init(),
         localize: @escaping (String) -> String = loc,
         allowsExternalActions: Bool = true,
         usesAsyncCredentials: Bool = false,
         loadModels: @escaping (String) async throws -> [OpenAIASRModel] = { try await OpenAIASRModelCatalog().fetch(apiKey: $0) }) {
        self.textFieldDelegate = textFieldDelegate
        self.editor = editor
        self.loadModels = loadModels
        self.localize = localize
        self.allowsExternalActions = allowsExternalActions
        self.usesAsyncCredentials = usesAsyncCredentials
        super.init()
    }

    private func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localize(key), arguments: arguments)
    }

    func makeView() -> NSView {
        makeView(includeContext: true, allowsModelFetch: true)
    }

    func makeView(includeContext: Bool, allowsModelFetch: Bool = true) -> NSView {
        self.allowsModelFetch = allowsModelFetch && allowsExternalActions
        modelRefreshButton?.isEnabled = self.allowsModelFetch && modelTask == nil && !isBusy
        if let cachedView { return cachedView }
        includesContextInConnection = includeContext
        let view = OpenAISettingsDocumentView()
        let description = SettingsUI.makeSecondaryLabel(text("openai.settings.desc"))
        SettingsUI.allowHorizontalWrapping(description, preferredMaxLayoutWidth: 560)
        description.translatesAutoresizingMaskIntoConstraints = false
        description.identifier = NSUserInterfaceItemIdentifier("openai.description")

        keyField = SettingsUI.makeSecureField(placeholder: text("openai.settings.keyPlaceholder"), delegate: textFieldDelegate)
        keyField.identifier = NSUserInterfaceItemIdentifier("openai.apiKey")
        let keyLink = NSButton(title: text("doubao.settings.apiKeyLink"), target: self, action: #selector(openAPIKeyPage(_:)))
        keyLink.bezelStyle = .accessoryBarAction
        keyLink.isBordered = false
        keyLink.contentTintColor = .linkColor
        keyLink.font = .systemFont(ofSize: 12)
        keyLink.isEnabled = allowsExternalActions
        keyLink.setContentHuggingPriority(.required, for: .horizontal)
        keyLink.setContentCompressionResistancePriority(.required, for: .horizontal)
        let remove = NSButton(title: text("openai.settings.removeKey"), target: self, action: #selector(removeKey(_:)))
        removeKeyButton = remove
        remove.identifier = NSUserInterfaceItemIdentifier("openai.removeKey")
        remove.bezelStyle = .accessoryBarAction
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 11)
        remove.contentTintColor = .secondaryLabelColor
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.setContentCompressionResistancePriority(.required, for: .horizontal)
        let keyRow = NSStackView(views: [keyField, keyLink])
        keyRow.spacing = 8
        keyRow.orientation = .horizontal
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel = SettingsUI.makeSecondaryLabel(fontSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("openai.keyStatus")
        SettingsUI.allowHorizontalWrapping(statusLabel, preferredMaxLayoutWidth: 320)
        let keyStatusRow = NSStackView(views: [statusLabel, remove])
        keyStatusRow.orientation = .horizontal
        keyStatusRow.spacing = 8
        keyStatusRow.alignment = .centerY

        modelPopup = NSPopUpButton()
        modelPopup.identifier = NSUserInterfaceItemIdentifier("openai.model")
        modelPopup.target = self
        modelPopup.action = #selector(changeModel(_:))
        modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelRefreshButton = SettingsUI.makeButton(text("openai.models.refresh"), target: self, action: #selector(refreshModels(_:)))
        modelRefreshButton.identifier = NSUserInterfaceItemIdentifier("openai.models.refresh")
        modelRefreshButton.bezelStyle = .accessoryBarAction
        modelRefreshButton.isBordered = false
        modelRefreshButton.font = .systemFont(ofSize: 12)
        modelRefreshButton.contentTintColor = .linkColor
        modelRefreshButton.setContentHuggingPriority(.required, for: .horizontal)
        modelRefreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let modelRow = NSStackView(views: [modelPopup, modelRefreshButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        modelStatusLabel = SettingsUI.makeSecondaryLabel(fontSize: 11)
        modelStatusLabel.identifier = NSUserInterfaceItemIdentifier("openai.models.status")
        SettingsUI.allowHorizontalWrapping(modelStatusLabel, preferredMaxLayoutWidth: 430)

        delayPopup = NSPopUpButton()
        delayPopup.identifier = NSUserInterfaceItemIdentifier("openai.delay")
        delayPopup.addItem(withTitle: text("openai.delay.default"))
        delayPopup.addItems(withTitles: [text("openai.delay.minimal"), text("openai.delay.low"),
                                        text("openai.delay.medium"), text("openai.delay.high"), text("openai.delay.xhigh")])
        delayPopup.toolTip = text("openai.delay.hint")
        languageField = SettingsUI.makeField(placeholder: text("openai.settings.languagesPlaceholder"), delegate: textFieldDelegate)
        languageField.identifier = NSUserInterfaceItemIdentifier("openai.languages")
        let prompt = makeTextArea(identifier: "openai.prompt", height: 60)
        promptView = prompt.1
        let keywords = makeTextArea(identifier: "openai.keywords", height: 60)
        keywordsView = keywords.1
        hintsLabel = SettingsUI.makeSecondaryLabel(text("openai.settings.hints"), fontSize: 11)
        hintsLabel.identifier = NSUserInterfaceItemIdentifier("openai.hints")
        SettingsUI.allowHorizontalWrapping(hintsLabel, preferredMaxLayoutWidth: 430)

        // 与豆包页沿用同一表单列、顺序和间距；状态说明归属对应控件。
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        var rows: [(String, NSView)] = [
            (text("doubao.settings.apiKey"), keyRow),
            ("", keyStatusRow),
            (text("doubao.settings.resourceID"), modelRow),
            ("", modelStatusLabel),
            (text("openai.settings.delay"), delayPopup),
            (text("openai.settings.languages"), languageField),
        ]
        if includeContext {
            let contextRows: [(String, NSView)] = [
                (text("openai.settings.prompt"), prompt.0),
                (text("openai.settings.keywords"), keywords.0),
                ("", hintsLabel),
            ]
            rows.append(contentsOf: contextRows)
        }
        for (label, control) in rows {
            let row = SettingsUI.makeFormRow(labelText: label, control: control)
            if let title = row.arrangedSubviews.first as? NSTextField {
                SettingsUI.allowHorizontalWrapping(title, preferredMaxLayoutWidth: 120)
            }
            content.addArrangedSubview(row)
        }
        view.wrappingLabels = [(description, 32), (modelStatusLabel, 160), (hintsLabel, 160),
                               (statusLabel, 168 + remove.intrinsicContentSize.width)]
        view.addSubview(description)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            description.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        SettingsUI.pinArrangedSubviewsTrailing(in: content)
        // 沿用设置页的原生滚动方式，窄窗口与长语言文案不挤压保存按钮。
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        modelRefreshButton.isEnabled = self.allowsModelFetch
        cachedView = scroll
        return scroll
    }

    /// 提示编辑器使用独立视图同步同一份草稿，不把连接表单里的控件移到另一个窗口。
    func makeHintsView() -> NSView {
        if let cachedHintsView { return cachedHintsView }
        if cachedView == nil {
            _ = makeView(includeContext: false, allowsModelFetch: false)
        }
        if editor.baseline == nil && !isBusy { refresh() }
        let prompt = makeTextArea(identifier: "openai.hints.prompt", height: 120)
        let keywords = makeTextArea(identifier: "openai.hints.keywords", height: 120)
        separatePromptView = prompt.1
        separateKeywordsView = keywords.1
        prompt.1.setAccessibilityLabel(text("preferences.hints.scene"))
        keywords.1.setAccessibilityLabel(text("openai.settings.keywords"))
        let sceneLabel = NSTextField(labelWithString: text("preferences.hints.scene"))
        let keywordsLabel = NSTextField(labelWithString: text("openai.settings.keywords"))
        sceneLabel.font = .systemFont(ofSize: 13)
        keywordsLabel.font = .systemFont(ofSize: 13)
        let content = NSStackView(views: [sceneLabel, prompt.0, keywordsLabel, keywords.0])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(16, after: prompt.0)
        content.translatesAutoresizingMaskIntoConstraints = false
        prompt.0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        keywords.0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        synchronizeHintsViews()
        cachedHintsView = content
        updateModelControls()
        updateBusyControls()
        return content
    }

    func textDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSTextView else { return }
        if changed === separatePromptView { promptView.string = changed.string }
        else if changed === separateKeywordsView { keywordsView.string = changed.string }
        else if changed === promptView { separatePromptView?.string = changed.string }
        else if changed === keywordsView { separateKeywordsView?.string = changed.string }
    }

    private func synchronizeHintsViews() {
        separatePromptView?.string = promptView?.string ?? ""
        separateKeywordsView?.string = keywordsView?.string ?? ""
    }

    @objc private func removeKey(_ sender: NSButton) {
        clearKey = true
        keyField.stringValue = ""
        apiKeyDidChange()
        statusLabel.stringValue = text("openai.settings.keyRemovalPending")
    }

    @objc private func openAPIKeyPage(_ sender: NSButton) {
        guard allowsExternalActions else { return }
        if let url = URL(string: "https://platform.openai.com/api-keys") { NSWorkspace.shared.open(url) }
    }

    private var selectedModel: OpenAIASRModel {
        (modelPopup?.selectedItem?.representedObject as? String).flatMap(OpenAIASRModel.init(rawValue:)) ?? .live
    }

    private func rebuildModels(selecting selected: OpenAIASRModel) {
        var choices = availableModels ?? OpenAIASRModel.allCases
        if !choices.contains(selected) { choices.append(selected) }
        modelPopup.removeAllItems()
        for model in choices {
            modelPopup.addItem(withTitle: model.rawValue)
            modelPopup.lastItem?.representedObject = model.rawValue
        }
        modelPopup.selectItem(withTitle: selected.rawValue)
    }

    @objc private func changeModel(_ sender: NSPopUpButton) { updateModelControls() }

    private func updateModelControls() {
        let model = selectedModel
        promptView.isEditable = model.supportsContext
        keywordsView.isEditable = model.supportsContext
        promptView.textColor = model.supportsContext ? .labelColor : .secondaryLabelColor
        keywordsView.textColor = model.supportsContext ? .labelColor : .secondaryLabelColor
        separatePromptView?.isEditable = model.supportsContext
        separateKeywordsView?.isEditable = model.supportsContext
        separatePromptView?.textColor = model.supportsContext ? .labelColor : .secondaryLabelColor
        separateKeywordsView?.textColor = model.supportsContext ? .labelColor : .secondaryLabelColor
        cachedHintsView?.isHidden = !model.supportsContext
        languageField.placeholderString = text(model.supportsMultipleLanguages ? "openai.settings.languagesPlaceholder" : "openai.settings.singleLanguagePlaceholder")
        languageField.toolTip = text(model.supportsMultipleLanguages ? "openai.settings.languageCodes" : "openai.settings.whisperLanguageCodes")
        hintsLabel.stringValue = text(model.supportsContext ? "openai.settings.hints" : "openai.settings.whisperHints")
        onContentSizeChanged?()
    }

    /// 只在 OpenAI 页真正显示时调用；窗口初始化其他页不会触发网络。
    func activateModelList() {
        if isLoadingCredentials { activateModelsAfterLoad = true; return }
        guard allowsModelFetch, !isBusy, !hasActivatedModels else { return }
        hasActivatedModels = true
        if effectiveAPIKey != nil { refreshModels(nil) }
    }

    func cancelModelListFetch() {
        activateModelsAfterLoad = false
        modelTask?.cancel()
        modelTask = nil
        modelRefreshButton?.isEnabled = allowsModelFetch && !isBusy
    }

    func apiKeyDidChange() {
        cancelModelListFetch()
        availableModels = nil
        hasActivatedModels = true
        rebuildModels(selecting: selectedModel)
        modelStatusLabel.stringValue = text("openai.models.keyChanged")
    }

    private var effectiveAPIKey: String? {
        guard !clearKey else { return nil }
        let entered = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        guard case .value(let saved) = editor.keyReadResult else { return nil }
        let value = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @objc private func refreshModels(_ sender: NSButton?) {
        guard allowsModelFetch, !isBusy else { return }
        cancelModelListFetch()
        guard let key = effectiveAPIKey else {
            modelStatusLabel.stringValue = text("openai.error.missingApiKey")
            return
        }
        modelRefreshButton.isEnabled = false
        modelStatusLabel.stringValue = text("openai.models.loading")
        let loader = loadModels
        modelTask = Task { @MainActor [weak self] in
            do {
                let models = try await loader(key)
                guard let self, !Task.isCancelled, self.effectiveAPIKey == key else { return }
                self.availableModels = models
                let selected = self.selectedModel
                self.rebuildModels(selecting: selected)
                if models.isEmpty {
                    self.modelStatusLabel.stringValue = text("openai.models.empty")
                } else {
                    self.modelStatusLabel.stringValue = text("openai.models.loaded", models.count)
                    if !models.contains(selected) {
                        self.modelStatusLabel.stringValue += " " + text("openai.models.unlisted")
                    }
                }
                self.modelRefreshButton.isEnabled = true
                self.modelTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.effectiveAPIKey == key else { return }
                self.modelStatusLabel.stringValue = text("openai.models.failed")
                if let failure = error as? CloudASRFailure { self.modelStatusLabel.stringValue += " " + failure.message }
                self.modelRefreshButton.isEnabled = true
                self.modelTask = nil
            }
        }
    }

    private func makeTextArea(identifier: String, height: CGFloat) -> (NSScrollView, NSTextView) {
        let text = NSTextView()
        text.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        text.identifier = NSUserInterfaceItemIdentifier(identifier)
        text.isRichText = false
        text.delegate = self
        text.font = .systemFont(ofSize: 12)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scroll, text)
    }

    func refresh() {
        guard !isBusy else { return }
        cancelModelListFetch()
        if usesAsyncCredentials {
            isLoadingCredentials = true
            updateBusyControls()
            refreshStatus()
            editor.reloadAsync { [weak self] value in
                guard let self else { return }
                self.isLoadingCredentials = false
                self.applyLoadedDraft(value)
                self.updateBusyControls()
                if self.activateModelsAfterLoad {
                    self.activateModelsAfterLoad = false
                    self.activateModelList()
                }
            }
        } else { applyLoadedDraft(editor.reload()) }
    }

    private func applyLoadedDraft(_ value: OpenAIASRSettingsDraft) {
        clearKey = false
        hasActivatedModels = false
        availableModels = nil
        keyField.stringValue = ""
        rebuildModels(selecting: value.configuration.resolvedModel)
        delayPopup.selectItem(at: value.configuration.delay.flatMap { delayValues.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        modelStatusLabel.stringValue = text("openai.models.initial")
        languageField.stringValue = value.configuration.languages.joined(separator: ", ")
        promptView.string = value.configuration.prompt
        keywordsView.string = value.configuration.keywords.joined(separator: "\n")
        synchronizeHintsViews()
        updateModelControls()
        refreshStatus()
    }

    func refreshStatus() {
        guard statusLabel != nil else { return }
        if isBusy { statusLabel.stringValue = text(isLoadingCredentials ? "settings.loading" : "settings.saving") }
        else if let error = editor.loadError {
            statusLabel.stringValue = error
        } else if clearKey {
            statusLabel.stringValue = text("openai.settings.keyRemovalPending")
        } else {
            switch editor.keyReadResult {
            case .value: statusLabel.stringValue = text("openai.settings.keyConfigured")
            case .notFound: statusLabel.stringValue = text("openai.error.missingApiKey")
            case .failure: statusLabel.stringValue = text("openai.error.keychainFailed")
            }
        }
    }

    private var draft: OpenAIASRSettingsDraft {
        var value = editor.baseline ?? .init(configuration: .init())
        value.configuration.model = selectedModel == .live ? nil : selectedModel
        value.configuration.delay = delayPopup.indexOfSelectedItem > 0 ? delayValues[delayPopup.indexOfSelectedItem - 1] : nil
        value.configuration.languages = languageField.stringValue.components(separatedBy: CharacterSet(charactersIn: ",， "))
            .filter { !$0.isEmpty }
        value.configuration.prompt = promptView.string
        value.configuration.keywords = keywordsView.string.components(separatedBy: .newlines)
        if !keyField.stringValue.isEmpty { value.keyEdit = .replace(keyField.stringValue) }
        else if clearKey { value.keyEdit = .clear }
        return value
    }

    var hasChanges: Bool { editor.baseline != nil && editor.hasChanges(draft) }
    var hasConnectionChanges: Bool { editor.baseline != nil && editor.hasChanges(connectionDraft) }
    var hasHintChanges: Bool {
        guard let value = hintsDraft else { return false }
        return editor.hasChanges(value)
    }

    private var connectionDraft: OpenAIASRSettingsDraft {
        var value = draft
        if !includesContextInConnection, let baseline = editor.baseline {
            value.configuration.prompt = baseline.configuration.prompt
            value.configuration.keywords = baseline.configuration.keywords
        }
        return value
    }

    /// 只从已加载的非敏感基线替换两个提示字段，不读取或提交连接密钥草稿。
    private var hintsDraft: OpenAIASRSettingsDraft? {
        guard var value = editor.baseline else { return nil }
        value.configuration.prompt = promptView.string
        value.configuration.keywords = keywordsView.string.components(separatedBy: .newlines)
        value.keyEdit = .unchanged
        return value
    }

    func saveHints() -> ASRSettingsTabSaveOutcome {
        guard !isBusy else { return .deferred }
        guard let value = hintsDraft else { return .saved }
        guard editor.loadError == nil else {
            return .failed(message: text("openai.error.invalidConfiguration"), color: .systemRed)
        }
        if usesAsyncCredentials { return saveAsync(value, scope: "hints") }
        do {
            try editor.save(value)
            refreshStatus()
            return .saved
        } catch let error as OpenAIASRSettingsError {
            return .failed(message: error.message, color: .systemRed)
        } catch {
            return .failed(message: text("openai.error.invalidConfiguration"), color: .systemRed)
        }
    }

    func discardHints() {
        guard !isBusy else { return }
        guard let baseline = editor.baseline else { return }
        promptView.string = baseline.configuration.prompt
        keywordsView.string = baseline.configuration.keywords.joined(separator: "\n")
        synchronizeHintsViews()
    }

    func discardConnectionChanges() {
        guard !isBusy, let baseline = editor.baseline else { return }
        cancelModelListFetch()
        let pendingPrompt = promptView.string
        let pendingKeywords = keywordsView.string
        applyLoadedDraft(baseline)
        if !includesContextInConnection {
            promptView.string = pendingPrompt
            keywordsView.string = pendingKeywords
            synchronizeHintsViews()
        }
    }

    private func updateBusyControls() {
        let enabled = !isBusy
        for control in [keyField, languageField, modelPopup, delayPopup] as [NSControl?] { control?.isEnabled = enabled }
        removeKeyButton?.isEnabled = enabled
        modelRefreshButton?.isEnabled = enabled && allowsModelFetch && modelTask == nil
        let editable = enabled && selectedModel.supportsContext
        for view in [promptView, keywordsView, separatePromptView, separateKeywordsView] { view?.isEditable = editable }
        onBusyChanged?()
    }

    private func saveAsync(_ value: OpenAIASRSettingsDraft, scope: String) -> ASRSettingsTabSaveOutcome {
        guard editor.hasChanges(value) else { return .saved }
        isSavingCredentials = true
        updateBusyControls()
        refreshStatus()
        editor.saveAsync(value) { [weak self] result in
            guard let self else { return }
            self.isSavingCredentials = false
            let outcome: ASRSettingsTabSaveOutcome
            switch result {
            case .success:
                if scope == "openai" { self.keyField.stringValue = ""; self.clearKey = false }
                outcome = .saved
            case .failure(let error):
                outcome = .failed(message: (error as? OpenAIASRSettingsError)?.message ?? self.text("openai.error.invalidConfiguration"), color: .systemRed)
            }
            self.updateBusyControls()
            self.refreshStatus()
            self.onOperationCompleted?(scope, outcome)
        }
        return .deferred
    }

    func save() -> ASRSettingsTabSaveOutcome {
        guard !isBusy else { return .deferred }
        if usesAsyncCredentials { return saveAsync(connectionDraft, scope: "openai") }
        do {
            try editor.save(connectionDraft)
            keyField.stringValue = ""
            clearKey = false
            refreshStatus()
            return .saved
        } catch let error as OpenAIASRSettingsError {
            return .failed(message: error.message, color: .systemRed)
        } catch {
            return .failed(message: text("openai.error.invalidConfiguration"), color: .systemRed)
        }
    }
}

private final class OpenAISettingsDocumentView: NSView {
    var wrappingLabels: [(NSTextField, CGFloat)] = []
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 按固定表单列计算换行宽度，避免标签自身尺寸反复反馈导致布局循环。
        for (label, reservedWidth) in wrappingLabels {
            let width = max(1, newSize.width - reservedWidth)
            if abs(label.preferredMaxLayoutWidth - width) > 0.5 {
                label.preferredMaxLayoutWidth = width
            }
        }
    }
}
