import Cocoa
import Speech

final class ASRSettingsWindowController: NSObject {
    private var window: NSWindow?
    private var tabView: NSTabView!

    // 豆包设置（Doubao settings）
    private var doubaoAPIKeyField: NSSecureTextField!
    private var doubaoResourceIDField: NSTextField!
    private var doubaoEndpointField: NSTextField!
    private var doubaoITNCheckbox: NSButton!
    private var doubaoDDCCheckbox: NSButton!
    private var doubaoNonstreamCheckbox: NSButton!
    private var doubaoGlobalInfoLabel: NSTextField!

    // Sherpa 设置（Sherpa settings）
    private var sherpaRadioButtons: [NSButton] = []
    private var sherpaButtonModelIDs: [NSButton: String] = [:]
    private var sherpaStatusLabel: NSTextField!
    private var sherpaDownloadButton: NSButton!

    // Apple 设置（Apple settings）
    private var appleEnableCheckbox: NSButton!
    private var appleStatusLabel: NSTextField!

    // 状态（Status）
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("asrSettings.title")
        w.isReleasedWhenClosed = false
        w.delegate = self

        guard let cv = w.contentView else { return }
        let pad: CGFloat = 24

        // 创建 TabView
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        // 标签页 1：豆包云端识别
        let doubaoTab = NSTabViewItem(identifier: "doubao")
        doubaoTab.label = loc("asrSettings.tab.doubao")
        doubaoTab.view = buildDoubaoTab()
        tabView.addTabViewItem(doubaoTab)

        // 标签页 2：Sherpa 本地识别
        let sherpaTab = NSTabViewItem(identifier: "sherpa")
        sherpaTab.label = loc("asrSettings.tab.sherpa")
        sherpaTab.view = buildSherpaTab()
        tabView.addTabViewItem(sherpaTab)

        // 标签页 3：Apple 离线识别
        let appleTab = NSTabViewItem(identifier: "apple")
        appleTab.label = loc("asrSettings.tab.apple")
        appleTab.view = buildAppleTab()
        tabView.addTabViewItem(appleTab)

        // 底部按钮
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let cancelBtn = makeButton(loc("settings.cancel"), action: #selector(cancelSettings(_:)))
        let saveBtn = makeButton(loc("settings.save"), action: #selector(saveSettings(_:)))
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = NSStackView(views: [statusLabel, cancelBtn, saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 布局
        cv.addSubview(tabView)
        cv.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),

            bottomRow.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 16),
            bottomRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            bottomRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            bottomRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),
        ])

        window = w
        refreshFields()
        w.center()
        w.recalculateKeyViewLoop()
        AppDelegate.bringToFront(w)
    }

    // MARK: - 豆包标签页（Doubao Tab）

    private func buildDoubaoTab() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("doubao.settings.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        doubaoAPIKeyField = makeSecureField(placeholder: "volc-...")
        doubaoAPIKeyField.toolTip = loc("tooltip.doubao.apiKey")
        doubaoResourceIDField = makeField(placeholder: VolcengineASRSettings.defaultResourceID)
        doubaoResourceIDField.toolTip = loc("tooltip.doubao.resourceID")
        doubaoEndpointField = makeField(placeholder: VolcengineASRSettings.defaultEndpoint)
        doubaoEndpointField.toolTip = loc("tooltip.doubao.endpoint")

        doubaoITNCheckbox = makeCheckbox(title: loc("doubao.settings.enableITN"), tooltip: loc("tooltip.doubao.enableITN"))
        doubaoDDCCheckbox = makeCheckbox(title: loc("doubao.settings.enableDDC"), tooltip: loc("tooltip.doubao.enableDDC"))
        doubaoNonstreamCheckbox = makeCheckbox(title: loc("doubao.settings.enableNonstream"), tooltip: loc("tooltip.doubao.enableNonstream"))

        let effectsStack = NSStackView(views: [doubaoITNCheckbox, doubaoDDCCheckbox, doubaoNonstreamCheckbox])
        effectsStack.orientation = .vertical
        effectsStack.spacing = 4
        effectsStack.alignment = .leading

        doubaoGlobalInfoLabel = NSTextField(labelWithString: "")
        doubaoGlobalInfoLabel.font = .systemFont(ofSize: 12)
        doubaoGlobalInfoLabel.textColor = .secondaryLabelColor
        doubaoGlobalInfoLabel.lineBreakMode = .byWordWrapping
        doubaoGlobalInfoLabel.maximumNumberOfLines = 0
        doubaoGlobalInfoLabel.toolTip = loc("tooltip.doubao.globalInfo")

        let labelW: CGFloat = 120
        func makeRow(labelText: String, control: NSView) -> NSView {
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: labelW).isActive = true

            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 8
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
            (loc("doubao.settings.apiKey"), doubaoAPIKeyField),
            (loc("doubao.settings.resourceID"), doubaoResourceIDField),
            (loc("doubao.settings.endpoint"), doubaoEndpointField),
            (loc("doubao.settings.effects"), effectsStack),
            (loc("doubao.settings.globalFollow"), doubaoGlobalInfoLabel),
        ]
        for row in rows {
            form.addArrangedSubview(makeRow(labelText: row.0, control: row.1))
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

        for subview in form.arrangedSubviews {
            subview.trailingAnchor.constraint(equalTo: form.trailingAnchor).isActive = true
        }

        return view
    }

    // MARK: - Sherpa 标签页（Sherpa Tab）

    private func buildSherpaTab() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("asrSettings.sherpa.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // 当前语言
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        let langLabel = NSTextField(labelWithString: loc("asrSettings.sherpa.currentLang") + " " + languageDisplayName(currentLang))
        langLabel.font = .systemFont(ofSize: 13)
        langLabel.translatesAutoresizingMaskIntoConstraints = false

        // 模型列表
        let radioStack = NSStackView()
        radioStack.orientation = .vertical
        radioStack.spacing = 8
        radioStack.alignment = .leading
        radioStack.translatesAutoresizingMaskIntoConstraints = false

        let presets = SherpaModelPreset.presetsForCurrentLanguage()
        let currentPreset = SherpaModelPreset.current

        sherpaRadioButtons = []
        sherpaButtonModelIDs = [:]
        for preset in presets {
            let radio = NSButton(radioButtonWithTitle: preset.displayName, target: self, action: #selector(sherpaModelSelected(_:)))
            sherpaButtonModelIDs[radio] = preset.id
            radio.state = preset.id == currentPreset.id ? .on : .off
            radio.translatesAutoresizingMaskIntoConstraints = false
            sherpaRadioButtons.append(radio)
            radioStack.addArrangedSubview(radio)
        }

        // 下载状态
        sherpaStatusLabel = NSTextField(labelWithString: "")
        sherpaStatusLabel.font = .systemFont(ofSize: 12)
        sherpaStatusLabel.textColor = .secondaryLabelColor
        sherpaStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 下载按钮
        sherpaDownloadButton = makeButton(loc("asrSettings.sherpa.download"), action: #selector(downloadSherpaModel(_:)))
        sherpaDownloadButton.translatesAutoresizingMaskIntoConstraints = false

        // 打开文件夹按钮
        let openFolderButton = makeButton(loc("menu.sherpaOpenFolder"), action: #selector(openSherpaFolder(_:)))
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [sherpaDownloadButton, openFolderButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(descLabel)
        view.addSubview(langLabel)
        view.addSubview(radioStack)
        view.addSubview(sherpaStatusLabel)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            langLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            langLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            radioStack.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: 12),
            radioStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            radioStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sherpaStatusLabel.topAnchor.constraint(equalTo: radioStack.bottomAnchor, constant: 12),
            sherpaStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            buttonRow.topAnchor.constraint(equalTo: sherpaStatusLabel.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        updateSherpaStatus()
        return view
    }

    // MARK: - Apple 标签页（Apple Tab）

    private func buildAppleTab() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("asrSettings.apple.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // 当前状态
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true

        appleStatusLabel = NSTextField(labelWithString: "")
        appleStatusLabel.font = .systemFont(ofSize: 13)
        appleStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateAppleStatus()

        // 启用复选框
        let isEnabled = UserDefaults.standard.bool(forKey: "appleOnDeviceRecognitionEnabled")
        appleEnableCheckbox = makeCheckbox(title: loc("asrSettings.apple.enable"), tooltip: "")
        appleEnableCheckbox.state = isEnabled ? .on : .off
        appleEnableCheckbox.isEnabled = isSupported
        appleEnableCheckbox.translatesAutoresizingMaskIntoConstraints = false

        // 注意事项
        let noteLabel = NSTextField(labelWithString: loc("asrSettings.apple.note"))
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 0
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        // 打开系统设置按钮
        let openSettingsButton = makeButton(loc("asrSettings.apple.openSettings"), action: #selector(openAppleSettings(_:)))
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(descLabel)
        view.addSubview(appleStatusLabel)
        view.addSubview(appleEnableCheckbox)
        view.addSubview(noteLabel)
        view.addSubview(openSettingsButton)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            appleStatusLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            appleStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            appleEnableCheckbox.topAnchor.constraint(equalTo: appleStatusLabel.bottomAnchor, constant: 12),
            appleEnableCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            noteLabel.topAnchor.constraint(equalTo: appleEnableCheckbox.bottomAnchor, constant: 16),
            noteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            openSettingsButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            openSettingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        return view
    }

    // MARK: - 辅助方法（Helper methods）

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

    private func refreshFields() {
        // 豆包设置
        let doubaoSettings = VolcengineASRSettings.load()
        doubaoAPIKeyField?.stringValue = doubaoSettings.apiKey
        doubaoResourceIDField?.stringValue = doubaoSettings.resourceID
        doubaoEndpointField?.stringValue = doubaoSettings.endpoint
        doubaoITNCheckbox?.state = doubaoSettings.enableITN ? .on : .off
        doubaoDDCCheckbox?.state = doubaoSettings.enableDDC ? .on : .off
        doubaoNonstreamCheckbox?.state = doubaoSettings.enableNonstream ? .on : .off
        doubaoGlobalInfoLabel?.stringValue = globalInfo(settings: doubaoSettings)

        // Sherpa 设置
        updateSherpaStatus()

        // Apple 设置
        updateAppleStatus()

        // 状态
        statusLabel?.stringValue = ""
    }

    private func globalInfo(settings: VolcengineASRSettings) -> String {
        let language = languageDisplayName(UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN")
        let punctuation = UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") ? loc("doubao.settings.globalOn") : loc("doubao.settings.globalOff")
        let delay = String(format: loc("doubao.settings.globalTimeoutValue"), Double(settings.endWindowSize) / 1000.0)
        return loc("doubao.settings.globalSummary", language, punctuation, delay)
    }

    private func updateSherpaStatus() {
        let currentPreset = SherpaModelPreset.current
        if currentPreset.isDownloaded {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " ✓ " + loc("asrSettings.sherpa.downloaded")
            sherpaStatusLabel?.textColor = .systemGreen
            sherpaDownloadButton?.isEnabled = false
        } else {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " " + loc("asrSettings.sherpa.notDownloaded")
            sherpaStatusLabel?.textColor = .systemOrange
            sherpaDownloadButton?.isEnabled = true
        }
    }

    private func updateAppleStatus() {
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true

        if isSupported {
            appleStatusLabel?.stringValue = loc("asrSettings.apple.status") + " ✓ " + loc("asrSettings.apple.modelDownloaded")
            appleStatusLabel?.textColor = .systemGreen
        } else {
            appleStatusLabel?.stringValue = loc("asrSettings.apple.status") + " " + loc("asrSettings.apple.modelNotDownloaded")
            appleStatusLabel?.textColor = .systemOrange
        }
    }

    // MARK: - 动作方法（Action methods）

    @objc private func sherpaModelSelected(_ sender: NSButton) {
        guard let modelID = sherpaButtonModelIDs[sender] else { return }
        // 更新单选按钮状态
        for radio in sherpaRadioButtons {
            radio.state = sherpaButtonModelIDs[radio] == modelID ? .on : .off
        }
        // 更新下载状态显示
        if let preset = SherpaModelPreset.allPresets.first(where: { $0.id == modelID }) {
            if preset.isDownloaded {
                sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " ✓ " + loc("asrSettings.sherpa.downloaded")
                sherpaStatusLabel?.textColor = .systemGreen
                sherpaDownloadButton?.isEnabled = false
            } else {
                sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " " + loc("asrSettings.sherpa.notDownloaded")
                sherpaStatusLabel?.textColor = .systemOrange
                sherpaDownloadButton?.isEnabled = true
            }
        }
    }

    @objc private func downloadSherpaModel(_ sender: NSButton) {
        // 获取选中的模型 ID
        let selectedID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] } ?? SherpaModelPreset.current.id
        guard let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) else { return }

        // 确认下载
        let alert = NSAlert()
        alert.messageText = loc("sherpa.download.title")
        alert.informativeText = loc("asrSettings.sherpa.download.confirm")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("sherpa.download.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))

        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            // 开始下载
            sherpaDownloadButton?.isEnabled = false
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloading")
            sherpaStatusLabel?.textColor = .systemBlue

            let downloader = SherpaModelDownloader.shared
            downloader.onProgress = { [weak self] current, total, progress, message in
                DispatchQueue.main.async {
                    self?.sherpaStatusLabel?.stringValue = message
                }
            }
            downloader.onComplete = { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.sherpaStatusLabel?.stringValue = loc("sherpa.download.complete")
                        self?.sherpaStatusLabel?.textColor = .systemGreen
                        self?.sherpaDownloadButton?.isEnabled = false
                        // 保存选中的模型
                        UserDefaults.standard.set(selectedID, forKey: "sherpaModelPresetID")
                    } else {
                        self?.sherpaStatusLabel?.stringValue = loc("sherpa.download.failed", error ?? "Unknown error")
                        self?.sherpaStatusLabel?.textColor = .systemRed
                        self?.sherpaDownloadButton?.isEnabled = true
                    }
                }
            }
            downloader.startDownload(preset: preset)
        }
    }

    @objc private func openSherpaFolder(_ sender: NSButton) {
        SherpaOnnxRecognizerController.openSupportDirectory()
    }

    @objc private func openAppleSettings(_ sender: NSButton) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func saveSettings(_ sender: NSButton) {
        // 保存豆包设置
        guard VolcengineASRSettings.saveAPIKey(doubaoAPIKeyField.stringValue) else {
            statusLabel.stringValue = loc("doubao.settings.keychainFailed")
            statusLabel.textColor = .systemRed
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(doubaoEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "doubaoASREndpoint")
        defaults.set(doubaoResourceIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "doubaoASRResourceID")
        defaults.set(doubaoITNCheckbox.state == .on, forKey: "doubaoASREnableITN")
        defaults.set(doubaoDDCCheckbox.state == .on, forKey: "doubaoASREnableDDC")
        defaults.set(doubaoNonstreamCheckbox.state == .on, forKey: "doubaoASREnableNonstream")

        // 保存 Sherpa 模型选择
        let selectedSherpaID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
        if let selectedID = selectedSherpaID {
            defaults.set(selectedID, forKey: "sherpaModelPresetID")
            if let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) {
                let ready = SherpaModelDownloader.allModelsReady(for: preset) || SherpaModelDownloader.repairExtractedFilesIfNeeded(for: preset)
                defaults.set(ready, forKey: "sherpaModelsReady")
            }
        }

        // 保存 Apple 设置
        let appleEnabled = appleEnableCheckbox.state == .on
        let currentLang = defaults.string(forKey: "selectedLanguage") ?? "zh-CN"
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true
        if appleEnabled && !isSupported {
            // 不支持时强制关闭
            defaults.set(false, forKey: "appleOnDeviceRecognitionEnabled")
        } else {
            defaults.set(appleEnabled, forKey: "appleOnDeviceRecognitionEnabled")
        }

        statusLabel.stringValue = loc("settings.saved")
        statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}

// MARK: - NSTabViewDelegate

extension ASRSettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // 标签页切换时刷新
        refreshFields()
    }
}

// MARK: - NSWindowDelegate

extension ASRSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            AppDelegate.resetActivationIfNeeded(closing: w)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension ASRSettingsWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
