import Cocoa

final class DoubaoSettingsWindowController: NSObject {
    private var window: NSWindow?
    private var apiKeyField: NSSecureTextField!
    private var resourceIDField: NSTextField!
    private var endpointField: NSTextField!
    private var itnCheckbox: NSButton!
    private var ddcCheckbox: NSButton!
    private var nonstreamCheckbox: NSButton!
    private var globalInfoLabel: NSTextField!
    private var statusLabel: NSTextField!

    func showWindow() {
        if let window {
            refreshFields()
            AppDelegate.bringToFront(window)
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
        let labelW: CGFloat = 120
        let gap: CGFloat = 8

        let descLabel = NSTextField(labelWithString: loc("doubao.settings.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        apiKeyField = makeSecureField(placeholder: "volc-...")
        apiKeyField.toolTip = loc("tooltip.doubao.apiKey")
        resourceIDField = makeField(placeholder: VolcengineASRSettings.defaultResourceID)
        resourceIDField.toolTip = loc("tooltip.doubao.resourceID")
        endpointField = makeField(placeholder: VolcengineASRSettings.defaultEndpoint)
        endpointField.toolTip = loc("tooltip.doubao.endpoint")

        itnCheckbox = makeCheckbox(title: loc("doubao.settings.enableITN"), tooltip: loc("tooltip.doubao.enableITN"))
        ddcCheckbox = makeCheckbox(title: loc("doubao.settings.enableDDC"), tooltip: loc("tooltip.doubao.enableDDC"))
        nonstreamCheckbox = makeCheckbox(title: loc("doubao.settings.enableNonstream"), tooltip: loc("tooltip.doubao.enableNonstream"))

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

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false

        let rows: [(String, NSView)] = [
            (loc("doubao.settings.apiKey"), apiKeyField),
            (loc("doubao.settings.resourceID"), resourceIDField),
            (loc("doubao.settings.endpoint"), endpointField),
            (loc("doubao.settings.effects"), effectsStack),
            (loc("doubao.settings.globalFollow"), globalInfoLabel),
        ]
        for row in rows {
            form.addArrangedSubview(makeRow(labelText: row.0, control: row.1))
        }

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let cancelBtn = makeButton(loc("settings.cancel"), action: #selector(cancelSettings(_:)))
        let saveBtn = makeButton(loc("settings.save"), action: #selector(saveSettings(_:)))
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = NSStackView(views: [statusLabel, cancelBtn, saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = gap
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        for subview in form.arrangedSubviews {
            subview.trailingAnchor.constraint(equalTo: form.trailingAnchor).isActive = true
        }

        window = w
        refreshFields()
        w.center()
        w.recalculateKeyViewLoop()
        AppDelegate.bringToFront(w)
    }

    private func makeField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        return field
    }

    private func makeSecureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        return field
    }

    private func makeCheckbox(title: String, tooltip: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.toolTip = tooltip
        return button
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        else { button.bezelStyle = .rounded }
        return button
    }

    private func refreshFields() {
        let settings = VolcengineASRSettings.load()
        apiKeyField?.stringValue = settings.apiKey
        resourceIDField?.stringValue = settings.resourceID
        endpointField?.stringValue = settings.endpoint
        itnCheckbox?.state = settings.enableITN ? .on : .off
        ddcCheckbox?.state = settings.enableDDC ? .on : .off
        nonstreamCheckbox?.state = settings.enableNonstream ? .on : .off
        globalInfoLabel?.stringValue = globalInfo(settings: settings)
        statusLabel?.stringValue = ""
    }

    private func globalInfo(settings: VolcengineASRSettings) -> String {
        let language = languageDisplayName(UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN")
        let punctuation = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") ? loc("doubao.settings.globalOn") : loc("doubao.settings.globalOff")
        let delay = String(format: loc("doubao.settings.globalTimeoutValue"), Double(settings.endWindowSize) / 1000.0)
        return loc("doubao.settings.globalSummary", language, punctuation, delay)
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "en-US": return "English"
        case "zh-CN": return "简体中文"
        case "zh-TW": return "繁體中文"
        case "ja-JP": return "日本語"
        case "ko-KR": return "한국어"
        case "es-ES": return "Español"
        case "fr-FR": return "Français"
        case "de-DE": return "Deutsch"
        default: return code
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        guard VolcengineASRSettings.saveAPIKey(apiKeyField.stringValue) else {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "doubaoASREndpoint")
        defaults.set(resourceIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "doubaoASRResourceID")
        defaults.set(itnCheckbox.state == .on, forKey: "doubaoASREnableITN")
        defaults.set(ddcCheckbox.state == .on, forKey: "doubaoASREnableDDC")
        defaults.set(nonstreamCheckbox.state == .on, forKey: "doubaoASREnableNonstream")

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
            AppDelegate.resetActivationIfNeeded(closing: w)
        }
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
