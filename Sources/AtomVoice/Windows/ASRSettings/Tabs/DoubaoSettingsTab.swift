import Cocoa

final class DoubaoSettingsTab: ASRSettingsTab {
    private static let apiKeyURLString = "https://console.volcengine.com/speech/new/setting/apikeys"

    let identifier = "doubao"
    let label = loc("asrSettings.tab.doubao")

    private weak var textFieldDelegate: NSTextFieldDelegate?
    private var doubaoAPIKeyField: NSSecureTextField!
    private var doubaoModelPopup: NSPopUpButton!
    private var doubaoEndpointField: NSTextField!
    private let doubaoModelOptions: [DoubaoModelKind] = [.v2, .v1]
    private var doubaoITNCheckbox: NSButton!
    private var doubaoDDCCheckbox: NSButton!
    private var doubaoNonstreamCheckbox: NSButton!
    private var doubaoGlobalInfoLabel: NSTextField!

    init(textFieldDelegate: NSTextFieldDelegate?) {
        self.textFieldDelegate = textFieldDelegate
    }

    func makeView() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("doubao.settings.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        SettingsUI.allowHorizontalWrapping(descLabel, preferredMaxLayoutWidth: 560)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        doubaoAPIKeyField = SettingsUI.makeSecureField(placeholder: "volc-...", delegate: textFieldDelegate)
        doubaoAPIKeyField.toolTip = loc("tooltip.doubao.apiKey")
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

        let apiKeyLink = NSButton(title: loc("doubao.settings.apiKeyLink"),
                                  target: self, action: #selector(openDoubaoAPIKeyPage(_:)))
        apiKeyLink.bezelStyle = .accessoryBarAction
        apiKeyLink.isBordered = false
        apiKeyLink.contentTintColor = .linkColor
        apiKeyLink.font = .systemFont(ofSize: 12)
        apiKeyLink.toolTip = Self.apiKeyURLString
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
            (loc("doubao.settings.apiKey"), apiKeyControlRow),
            (loc("doubao.settings.resourceID"), doubaoModelPopup),
            (loc("doubao.settings.endpoint"), doubaoEndpointField),
            (loc("doubao.settings.effects"), effectsStack),
            (loc("doubao.settings.globalFollow"), doubaoGlobalInfoLabel),
        ]
        for row in rows {
            form.addArrangedSubview(SettingsUI.makeFormRow(labelText: row.0, control: row.1))
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
        ])

        SettingsUI.pinArrangedSubviewsTrailing(in: form)

        return view
    }

    func refresh() {
        let doubaoSettings = VolcengineASRSettings.load()
        doubaoAPIKeyField?.stringValue = doubaoSettings.apiKey
        let currentKind = DoubaoModelKind.from(resourceID: doubaoSettings.resourceID)
        if let idx = doubaoModelOptions.firstIndex(of: currentKind) {
            doubaoModelPopup?.selectItem(at: idx)
        }
        doubaoEndpointField?.stringValue = doubaoSettings.endpoint
        doubaoITNCheckbox?.state = doubaoSettings.enableITN ? .on : .off
        doubaoDDCCheckbox?.state = doubaoSettings.enableDDC ? .on : .off
        doubaoNonstreamCheckbox?.state = doubaoSettings.enableNonstream ? .on : .off
        doubaoGlobalInfoLabel?.stringValue = doubaoSettings.globalSummary
    }

    func save() -> ASRSettingsTabSaveOutcome {
        guard VolcengineASRSettings.saveAPIKey(doubaoAPIKeyField.stringValue) else {
            return .failed(message: loc("doubao.settings.keychainFailed"), color: .systemRed)
        }

        let selectedKind = doubaoModelOptions[doubaoModelPopup.indexOfSelectedItem]
        VolcengineASRSettings(
            endpoint: doubaoEndpointField.stringValue,
            apiKey: doubaoAPIKeyField.stringValue,
            resourceID: selectedKind.resourceID,
            enableITN: doubaoITNCheckbox.state == .on,
            enableDDC: doubaoDDCCheckbox.state == .on,
            enableNonstream: doubaoNonstreamCheckbox.state == .on,
            selectedLanguage: AppSettings.selectedLanguage
        ).persistNonSecretFields()
        return .saved
    }

    @objc private func openDoubaoAPIKeyPage(_ sender: NSButton) {
        if let url = URL(string: Self.apiKeyURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}
