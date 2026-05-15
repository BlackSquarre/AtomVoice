import Cocoa

final class DoubaoSettingsWindowController: NSObject {
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var apiKeyField: NSSecureTextField!
    private var modelPopup: NSPopUpButton!
    private var endpointField: NSTextField!
    private let modelOptions: [DoubaoModelKind] = [.v2, .v1]
    private var itnCheckbox: NSButton!
    private var ddcCheckbox: NSButton!
    private var nonstreamCheckbox: NSButton!
    private var globalInfoLabel: NSTextField!
    private var statusLabel: NSTextField!

    func showWindow() {
        if let window {
            refreshFields()
            WindowPresenter.shared.bringToFront(window)
            return
        }
        buildWindow()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("doubao.settings.title")
        w.isReleasedWhenClosed = false
        w.delegate = self

        guard let cv = w.contentView else { return }
        let pad: CGFloat = 24
        let gap: CGFloat = 8

        let descLabel = NSTextField(labelWithString: loc("doubao.settings.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        apiKeyField = SettingsUI.makeSecureField(placeholder: "volc-...", delegate: self)
        apiKeyField.toolTip = loc("tooltip.doubao.apiKey")
        modelPopup = NSPopUpButton()
        modelPopup.toolTip = loc("tooltip.doubao.resourceID")
        for option in modelOptions {
            switch option {
            case .v2: modelPopup.addItem(withTitle: loc("doubao.model.v2"))
            case .v1: modelPopup.addItem(withTitle: loc("doubao.model.v1"))
            }
        }
        endpointField = SettingsUI.makeField(placeholder: VolcengineASRSettings.defaultEndpoint, delegate: self)
        endpointField.toolTip = loc("tooltip.doubao.endpoint")

        itnCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableITN"), tooltip: loc("tooltip.doubao.enableITN"))
        ddcCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableDDC"), tooltip: loc("tooltip.doubao.enableDDC"))
        nonstreamCheckbox = SettingsUI.makeCheckbox(title: loc("doubao.settings.enableNonstream"), tooltip: loc("tooltip.doubao.enableNonstream"))

        let effectsStack = NSStackView(views: [itnCheckbox, ddcCheckbox, nonstreamCheckbox])
        effectsStack.orientation = .vertical
        effectsStack.spacing = 4
        effectsStack.alignment = .leading

        globalInfoLabel = NSTextField(labelWithString: "")
        globalInfoLabel.font = .systemFont(ofSize: 12)
        globalInfoLabel.textColor = .secondaryLabelColor
        globalInfoLabel.lineBreakMode = .byWordWrapping
        globalInfoLabel.maximumNumberOfLines = 0
        globalInfoLabel.toolTip = loc("tooltip.doubao.globalInfo")

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false

        let rows: [(String, NSView)] = [
            (loc("doubao.settings.apiKey"), apiKeyField),
            (loc("doubao.settings.resourceID"), modelPopup),
            (loc("doubao.settings.endpoint"), endpointField),
            (loc("doubao.settings.effects"), effectsStack),
            (loc("doubao.settings.globalFollow"), globalInfoLabel),
        ]
        for row in rows {
            form.addArrangedSubview(SettingsUI.makeFormRow(labelText: row.0, control: row.1, spacing: gap))
        }

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = SettingsUI.makeSecondaryLabel()

        let cancelBtn = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let saveBtn = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [cancelBtn, saveBtn], spacing: gap)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        [descLabel, form, sep, bottomRow].forEach {
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),

            descLabel.topAnchor.constraint(equalTo: root.topAnchor),
            descLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            form.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sep.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 18),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bottomRow.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 16),
            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        SettingsUI.pinArrangedSubviewsTrailing(in: form)

        window = w
        refreshFields()
        w.center()
        w.recalculateKeyViewLoop()
        WindowPresenter.shared.bringToFront(w)
    }

    private func refreshFields() {
        let settings = VolcengineASRSettings.load()
        apiKeyField?.stringValue = settings.apiKey
        let currentKind = DoubaoModelKind.from(resourceID: settings.resourceID)
        if let idx = modelOptions.firstIndex(of: currentKind) {
            modelPopup?.selectItem(at: idx)
        }
        endpointField?.stringValue = settings.endpoint
        itnCheckbox?.state = settings.enableITN ? .on : .off
        ddcCheckbox?.state = settings.enableDDC ? .on : .off
        nonstreamCheckbox?.state = settings.enableNonstream ? .on : .off
        globalInfoLabel?.stringValue = settings.globalSummary
        statusLabel?.stringValue = ""
    }

    @objc private func saveSettings(_ sender: NSButton) {
        guard VolcengineASRSettings.saveAPIKey(apiKeyField.stringValue) else {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            return
        }

        let selectedKind = modelOptions[modelPopup.indexOfSelectedItem]
        VolcengineASRSettings(
            endpoint: endpointField.stringValue,
            apiKey: apiKeyField.stringValue,
            resourceID: selectedKind.resourceID,
            enableITN: itnCheckbox.state == .on,
            enableDDC: ddcCheckbox.state == .on,
            enableNonstream: nonstreamCheckbox.state == .on,
            selectedLanguage: AppSettings.selectedLanguage
        ).persistNonSecretFields()

        statusLabel.stringValue = loc("settings.saved")
        statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}

extension DoubaoSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
    }
}

extension DoubaoSettingsWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
