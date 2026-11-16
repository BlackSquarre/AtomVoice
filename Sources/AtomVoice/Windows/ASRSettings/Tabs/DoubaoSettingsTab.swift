import Cocoa

final class DoubaoSettingsTab: ASRSettingsTab {
    let identifier = "doubao"
    let label = loc("asrSettings.tab.doubao")

    private weak var textFieldDelegate: NSTextFieldDelegate?
    private var doubaoAPIKeyField: NSSecureTextField!
    private let editor: DoubaoSettingsEditor
    private var doubaoModelPopup: NSPopUpButton!
    private var doubaoEndpointField: NSTextField!
    private var servicePopup: NSPopUpButton!
    private var selectedService: DoubaoService = .china
    private var endpointRow: NSView!
    private var serviceInfoLabel: NSTextField!
    private var apiKeyLink: NSButton!
    private let doubaoModelOptions: [DoubaoModelKind] = [.v2, .v1]
    private var doubaoITNCheckbox: NSButton!
    private var doubaoDDCCheckbox: NSButton!
    private var doubaoNonstreamCheckbox: NSButton!
    private var doubaoGlobalInfoLabel: NSTextField!

    private let usesAsyncCredentials: Bool
    private(set) var isBusy = false
    var onBusyChanged: (() -> Void)?
    var onOperationCompleted: ((ASRSettingsTabSaveOutcome) -> Void)?

    init(textFieldDelegate: NSTextFieldDelegate?, editor: DoubaoSettingsEditor = DoubaoSettingsEditor(), usesAsyncCredentials: Bool = false) {
        self.textFieldDelegate = textFieldDelegate
        self.editor = editor
        self.usesAsyncCredentials = usesAsyncCredentials
    }

    func makeView() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("doubao.settings.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        SettingsUI.allowHorizontalWrapping(descLabel, preferredMaxLayoutWidth: 560)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        doubaoAPIKeyField = SettingsUI.makeSecureField(placeholder: "API Key", delegate: textFieldDelegate)
        doubaoAPIKeyField.toolTip = loc("tooltip.doubao.apiKey")
        doubaoAPIKeyField.identifier = NSUserInterfaceItemIdentifier("doubao.apiKey")
        doubaoModelPopup = NSPopUpButton()
        doubaoModelPopup.toolTip = loc("tooltip.doubao.resourceID")
        for option in doubaoModelOptions {
            switch option {
            case .v2: doubaoModelPopup.addItem(withTitle: loc("doubao.model.v2"))
            case .v1: doubaoModelPopup.addItem(withTitle: loc("doubao.model.v1"))
            }
        }
        doubaoEndpointField = SettingsUI.makeField(placeholder: VolcengineASRSettings.defaultEndpoint, delegate: textFieldDelegate)
        doubaoEndpointField.toolTip = loc("tooltip.doubao.endpoint")
        doubaoEndpointField.identifier = NSUserInterfaceItemIdentifier("doubao.endpoint")
        servicePopup = NSPopUpButton()
        servicePopup.identifier = NSUserInterfaceItemIdentifier("doubao.service")
        DoubaoService.allCases.forEach { servicePopup.addItem(withTitle: $0.title) }
        servicePopup.target = self
        servicePopup.action = #selector(changeService(_:))
        serviceInfoLabel = SettingsUI.makeSecondaryLabel()
        serviceInfoLabel.identifier = NSUserInterfaceItemIdentifier("doubao.keyStatus")
        SettingsUI.allowHorizontalWrapping(serviceInfoLabel, preferredMaxLayoutWidth: 430)

        apiKeyLink = NSButton(title: loc("doubao.settings.apiKeyLink"),
                                  target: self, action: #selector(openDoubaoAPIKeyPage(_:)))
        apiKeyLink.bezelStyle = .accessoryBarAction
        apiKeyLink.identifier = NSUserInterfaceItemIdentifier("doubao.apiKeyLink")
        apiKeyLink.isBordered = false
        apiKeyLink.contentTintColor = .linkColor
        apiKeyLink.font = .systemFont(ofSize: 12)
        apiKeyLink.translatesAutoresizingMaskIntoConstraints = false

        doubaoAPIKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        doubaoAPIKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apiKeyLink.setContentHuggingPriority(.required, for: .horizontal)
        apiKeyLink.setContentCompressionResistancePriority(.required, for: .horizontal)

        let apiKeyControlRow = NSStackView(views: [doubaoAPIKeyField, apiKeyLink])
        apiKeyControlRow.orientation = .horizontal
        apiKeyControlRow.spacing = 8
        apiKeyControlRow.alignment = .centerY
        apiKeyControlRow.translatesAutoresizingMaskIntoConstraints = false

        doubaoITNCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableITN"), tooltip: loc("tooltip.doubao.enableITN"))
        doubaoDDCCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableDDC"), tooltip: loc("tooltip.doubao.enableDDC"))
        doubaoNonstreamCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableNonstream"), tooltip: loc("tooltip.doubao.enableNonstream"))

        let effectsStack = NSStackView(views: [doubaoITNCheckbox, doubaoDDCCheckbox, doubaoNonstreamCheckbox])
        effectsStack.orientation = .vertical
        effectsStack.spacing = 4
        effectsStack.alignment = .leading

        doubaoGlobalInfoLabel = NSTextField(labelWithString: "")
        doubaoGlobalInfoLabel.font = .systemFont(ofSize: 12)
        doubaoGlobalInfoLabel.textColor = .secondaryLabelColor
        SettingsUI.allowHorizontalWrapping(doubaoGlobalInfoLabel, preferredMaxLayoutWidth: 430)
        doubaoGlobalInfoLabel.toolTip = loc("tooltip.doubao.globalInfo")

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false

        let rows: [(String, NSView)] = [
            (loc("doubao.settings.service"), servicePopup),
            ("", serviceInfoLabel),
            (loc("doubao.settings.apiKey"), apiKeyControlRow),
            (loc("doubao.settings.resourceID"), doubaoModelPopup),
            (loc("doubao.settings.endpoint"), doubaoEndpointField),
            (loc("doubao.settings.effects"), effectsStack),
            (loc("doubao.settings.globalFollow"), doubaoGlobalInfoLabel),
        ]
        for row in rows {
            let rowView = SettingsUI.makeFormRow(labelText: row.0, control: row.1)
            if row.1 === doubaoEndpointField { endpointRow = rowView }
            form.addArrangedSubview(rowView)
        }

        view.addSubview(descLabel)
        view.addSubview(form)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            form.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            form.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
        ])

        SettingsUI.pinArrangedSubviewsTrailing(in: form)

        return view
    }

    func refresh() {
        guard !isBusy else { return }
        if usesAsyncCredentials {
            setBusy(true)
            serviceInfoLabel.stringValue = loc("settings.loading")
            editor.reloadAsync { [weak self] value in
                self?.applyLoadedSettings(value)
                self?.setBusy(false)
            }
        } else { applyLoadedSettings(editor.reload()) }
    }

    private func applyLoadedSettings(_ doubaoSettings: VolcengineASRSettings) {
        applyServiceDraft(DoubaoSettingsDraft(settings: doubaoSettings))
        let currentKind = DoubaoModelKind.from(resourceID: doubaoSettings.resourceID)
        if let idx = doubaoModelOptions.firstIndex(of: currentKind) {
            doubaoModelPopup?.selectItem(at: idx)
        }
        doubaoITNCheckbox?.state = doubaoSettings.enableITN ? .on : .off
        doubaoDDCCheckbox?.state = doubaoSettings.enableDDC ? .on : .off
        doubaoNonstreamCheckbox?.state = doubaoSettings.enableNonstream ? .on : .off
        doubaoGlobalInfoLabel?.stringValue = doubaoSettings.globalSummary
    }

    private var draft: DoubaoSettingsDraft {
        var value = editor.baseline!
        value.service = selectedService
        value.apiKey = doubaoAPIKeyField.stringValue
        value.model = doubaoModelOptions[doubaoModelPopup.indexOfSelectedItem]
        value.endpoint = doubaoEndpointField.stringValue
        value.enableITN = doubaoITNCheckbox.state == .on
        value.enableDDC = doubaoDDCCheckbox.state == .on
        value.enableNonstream = doubaoNonstreamCheckbox.state == .on
        return value
    }

    private func applyServiceDraft(_ value: DoubaoSettingsDraft) {
        selectedService = value.service
        servicePopup.selectItem(at: DoubaoService.allCases.firstIndex(of: value.service)!)
        doubaoAPIKeyField.stringValue = value.apiKey
        doubaoEndpointField.stringValue = value.endpoint
        endpointRow.isHidden = value.service != .custom
        apiKeyLink.isHidden = value.service.apiKeyURL == nil
        apiKeyLink.toolTip = value.service.apiKeyURL?.absoluteString
        updateServiceInfo()
    }

    @objc private func changeService(_ sender: NSPopUpButton) {
        guard !isBusy, editor.baseline != nil else { return }
        let next = DoubaoService.allCases[sender.indexOfSelectedItem]
        if usesAsyncCredentials {
            let current = draft
            setBusy(true)
            serviceInfoLabel.stringValue = loc("settings.loading")
            editor.switchAsync(to: next, from: current) { [weak self] value in
                self?.applyServiceDraft(value)
                self?.setBusy(false)
            }
        } else { applyServiceDraft(editor.switching(to: next, from: draft)) }
    }

    var hasChanges: Bool { editor.baseline != nil && editor.hasChanges(draft) }

    func save() -> ASRSettingsTabSaveOutcome {
        guard !isBusy, editor.baseline != nil else { return .deferred }
        if usesAsyncCredentials {
            let current = draft
            guard editor.hasChanges(current) else { return .saved }
            setBusy(true)
            serviceInfoLabel.stringValue = loc("settings.saving")
            editor.saveAsync(current) { [weak self] saved in
                guard let self else { return }
                self.updateServiceInfo()
                self.setBusy(false)
                self.onOperationCompleted?(saved ? .saved : .failed(message: loc("doubao.settings.keychainFailed"), color: .systemRed))
            }
            return .deferred
        }
        guard editor.save(draft) else {
            return .failed(message: loc("doubao.settings.keychainFailed"), color: .systemRed)
        }
        return .saved
    }

    private func updateServiceInfo() {
        if case .failure = editor.keyReadResult(for: selectedService) {
            serviceInfoLabel.stringValue = loc("doubao.settings.keychainFailed")
            serviceInfoLabel.textColor = .systemRed
        } else {
            serviceInfoLabel.stringValue = selectedService.info
            serviceInfoLabel.textColor = .secondaryLabelColor
        }
    }

    private func setBusy(_ value: Bool) {
        isBusy = value
        for control in [doubaoAPIKeyField, doubaoModelPopup, doubaoEndpointField, servicePopup,
                        doubaoITNCheckbox, doubaoDDCCheckbox, doubaoNonstreamCheckbox] as [NSControl?] {
            control?.isEnabled = !value
        }
        onBusyChanged?()
    }

    @objc private func openDoubaoAPIKeyPage(_ sender: NSButton) {
        if let url = selectedService.apiKeyURL {
            NSWorkspace.shared.open(url)
        }
    }
}
