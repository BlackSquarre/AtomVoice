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
    private var sherpaDeleteButton: NSButton!
    private var sherpaLanguagePopup: NSPopUpButton!
    private var sherpaRadioStack: NSStackView!

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

        // 标签页 1：Sherpa 本地识别
        let sherpaTab = NSTabViewItem(identifier: "sherpa")
        sherpaTab.label = loc("asrSettings.tab.sherpa")
        sherpaTab.view = buildSherpaTab()
        tabView.addTabViewItem(sherpaTab)

        // 标签页 2：Apple 离线识别
        let appleTab = NSTabViewItem(identifier: "apple")
        appleTab.label = loc("asrSettings.tab.apple")
        appleTab.view = buildAppleTab()
        tabView.addTabViewItem(appleTab)

        // 标签页 3：豆包云端识别
        let doubaoTab = NSTabViewItem(identifier: "doubao")
        doubaoTab.label = loc("asrSettings.tab.doubao")
        doubaoTab.view = buildDoubaoTab()
        tabView.addTabViewItem(doubaoTab)

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

        // 默认显示当前选中的识别引擎对应的标签页
        // (Default to the tab matching the currently selected ASR engine)
        let currentEngine = ASREngineRegistry.shared.normalizedCode(for: UserDefaults.standard.string(forKey: "recognitionEngine"))
        let tabIdentifier: String
        switch currentEngine {
        case VolcengineASRSettings.engineCode: tabIdentifier = "doubao"
        case ASREngineRegistry.sherpaCode: tabIdentifier = "sherpa"
        default: tabIdentifier = "apple"
        }
        let tabIndex = tabView.indexOfTabViewItem(withIdentifier: tabIdentifier)
        if tabIndex != NSNotFound {
            tabView.selectTabViewItem(at: tabIndex)
        }

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

        // 识别语言下拉（与 UI 语言独立）（Recognition language popup, decoupled from UI language）
        let langTitle = NSTextField(labelWithString: loc("asrSettings.sherpa.recognitionLanguage"))
        langTitle.font = .systemFont(ofSize: 13)
        langTitle.translatesAutoresizingMaskIntoConstraints = false

        sherpaLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sherpaLanguagePopup.translatesAutoresizingMaskIntoConstraints = false
        sherpaLanguagePopup.target = self
        sherpaLanguagePopup.action = #selector(sherpaLanguageChanged(_:))
        let currentRecLang = SherpaModelPreset.recognitionLanguage
        for code in SherpaModelPreset.supportedRecognitionLanguages {
            let item = NSMenuItem(title: recognitionLanguageDisplayName(code), action: nil, keyEquivalent: "")
            item.representedObject = code
            sherpaLanguagePopup.menu?.addItem(item)
            if code == currentRecLang {
                sherpaLanguagePopup.select(item)
            }
        }

        let langRow = NSStackView(views: [langTitle, sherpaLanguagePopup])
        langRow.orientation = .horizontal
        langRow.spacing = 8
        langRow.alignment = .centerY
        langRow.translatesAutoresizingMaskIntoConstraints = false

        // 模型列表（按"已下载/可下载"分组渲染）（Model list, grouped by downloaded/available）
        sherpaRadioStack = NSStackView()
        sherpaRadioStack.orientation = .vertical
        sherpaRadioStack.spacing = 6
        sherpaRadioStack.alignment = .leading
        sherpaRadioStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSherpaModelList()

        // 下载状态
        sherpaStatusLabel = NSTextField(labelWithString: "")
        sherpaStatusLabel.font = .systemFont(ofSize: 12)
        sherpaStatusLabel.textColor = .secondaryLabelColor
        sherpaStatusLabel.lineBreakMode = .byWordWrapping
        sherpaStatusLabel.maximumNumberOfLines = 0
        sherpaStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 下载 / 删除 / 打开文件夹按钮（Download / Delete / Open folder buttons）
        sherpaDownloadButton = makeButton(loc("asrSettings.sherpa.download"), action: #selector(downloadSherpaModel(_:)))
        sherpaDownloadButton.translatesAutoresizingMaskIntoConstraints = false

        sherpaDeleteButton = makeButton(loc("asrSettings.sherpa.delete"), action: #selector(deleteSherpaModel(_:)))
        sherpaDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let openFolderButton = makeButton(loc("menu.sherpaOpenFolder"), action: #selector(openSherpaFolder(_:)))
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [sherpaDownloadButton, sherpaDeleteButton, openFolderButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // 第二行：导入模型包 + 指向 sherpa-onnx 模型列表的链接
        // (Second row: import button + link to sherpa-onnx model list)
        let importButton = makeButton(loc("asrSettings.sherpa.import"), action: #selector(importSherpaModel(_:)))
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.toolTip = loc("asrSettings.sherpa.import.tooltip")

        let githubLink = NSButton(title: loc("asrSettings.sherpa.modelListLink"),
                                  target: self, action: #selector(openSherpaModelList(_:)))
        githubLink.bezelStyle = .accessoryBarAction
        githubLink.isBordered = false
        githubLink.contentTintColor = .linkColor
        githubLink.font = .systemFont(ofSize: 12)
        githubLink.toolTip = "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models"
        githubLink.translatesAutoresizingMaskIntoConstraints = false

        let importRowSpacer = NSView()
        importRowSpacer.translatesAutoresizingMaskIntoConstraints = false
        importRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let importRow = NSStackView(views: [importButton, importRowSpacer, githubLink])
        importRow.orientation = .horizontal
        importRow.spacing = 8
        importRow.alignment = .centerY
        importRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(descLabel)
        view.addSubview(langRow)
        view.addSubview(sherpaRadioStack)
        view.addSubview(sherpaStatusLabel)
        view.addSubview(buttonRow)
        view.addSubview(importRow)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            langRow.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            langRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            sherpaRadioStack.topAnchor.constraint(equalTo: langRow.bottomAnchor, constant: 12),
            sherpaRadioStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            sherpaRadioStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sherpaStatusLabel.topAnchor.constraint(equalTo: sherpaRadioStack.bottomAnchor, constant: 12),
            sherpaStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sherpaStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonRow.topAnchor.constraint(equalTo: sherpaStatusLabel.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            importRow.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            importRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            importRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        updateSherpaStatus()
        return view
    }

    /// 按当前识别语言重建模型列表，已下载组在前
    /// (Rebuild model list under current recognition language, downloaded group first)
    private func rebuildSherpaModelList() {
        sherpaRadioStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sherpaRadioButtons = []
        sherpaButtonModelIDs = [:]

        let lang = SherpaModelPreset.recognitionLanguage
        let presets = SherpaModelPreset.presets(forRecognitionLanguage: lang)
        let downloaded = presets.filter { $0.isDownloaded }
        let pending = presets.filter { !$0.isDownloaded }

        // 当前选择的 preset id：若已不在当前语言列表中则回退到该语言的默认
        // (Current preset id; fall back to language default if it's not in this language's list)
        let savedID = UserDefaults.standard.string(forKey: "sherpaModelPresetID")
        let validIDs = Set(presets.map { $0.id })
        let activeID = savedID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? SherpaModelPreset.defaultModelID(forRecognitionLanguage: lang)

        if !downloaded.isEmpty {
            sherpaRadioStack.addArrangedSubview(makeGroupHeader(loc("asrSettings.sherpa.group.downloaded")))
            for preset in downloaded {
                sherpaRadioStack.addArrangedSubview(makeModelRadio(preset: preset, isDownloaded: true, activeID: activeID))
            }
        }
        if !pending.isEmpty {
            if !downloaded.isEmpty {
                sherpaRadioStack.addArrangedSubview(makeGroupHeader(loc("asrSettings.sherpa.group.available")))
            }
            for preset in pending {
                sherpaRadioStack.addArrangedSubview(makeModelRadio(preset: preset, isDownloaded: false, activeID: activeID))
            }
        }

        // 空状态提示：当前语言下无任何内置或导入的预设（Empty state: no built-in or imported presets for this language）
        if presets.isEmpty {
            let label = NSTextField(labelWithString: loc("asrSettings.sherpa.empty"))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            sherpaRadioStack.addArrangedSubview(label)
        }
    }

    private func makeGroupHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeModelRadio(preset: SherpaModelPreset, isDownloaded: Bool, activeID: String) -> NSButton {
        let mark = isDownloaded ? "✓ " : ""
        let title = "\(mark)\(preset.id) (\(preset.sizeMB)MB)"
        let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(sherpaModelSelected(_:)))
        sherpaButtonModelIDs[radio] = preset.id
        radio.state = preset.id == activeID ? .on : .off
        radio.translatesAutoresizingMaskIntoConstraints = false
        sherpaRadioButtons.append(radio)
        return radio
    }

    private func recognitionLanguageDisplayName(_ code: String) -> String {
        if code == "bilingual" { return loc("asrSettings.sherpa.lang.bilingual") }
        return languageDisplayName(code)
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
        let selectedID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
            ?? SherpaModelPreset.current.id
        let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) ?? SherpaModelPreset.current

        if preset.isDownloaded {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " ✓ " + loc("asrSettings.sherpa.downloaded")
            sherpaStatusLabel?.textColor = .systemGreen
            sherpaDownloadButton?.isEnabled = false
            sherpaDeleteButton?.isEnabled = true
        } else {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloadStatus") + " " + loc("asrSettings.sherpa.notDownloaded")
            sherpaStatusLabel?.textColor = .systemOrange
            // 导入预设没有下载源，按钮永远禁用（Imported presets have no source — disable download button）
            sherpaDownloadButton?.isEnabled = !preset.isImported
            sherpaDeleteButton?.isEnabled = false
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
        for radio in sherpaRadioButtons {
            radio.state = sherpaButtonModelIDs[radio] == modelID ? .on : .off
        }
        updateSherpaStatus()
    }

    @objc private func sherpaLanguageChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let code = item.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: SherpaModelPreset.recognitionLanguageKey)
        // 切换语言后，若当前 preset 不在新语言列表中，自动切到该语言默认模型
        // (After language switch, if current preset isn't in new list, auto-select language default)
        let presets = SherpaModelPreset.presets(forRecognitionLanguage: code)
        let savedID = UserDefaults.standard.string(forKey: "sherpaModelPresetID")
        if savedID == nil || !presets.contains(where: { $0.id == savedID }) {
            UserDefaults.standard.set(SherpaModelPreset.defaultModelID(forRecognitionLanguage: code), forKey: "sherpaModelPresetID")
        }
        rebuildSherpaModelList()
        updateSherpaStatus()
    }

    @objc private func deleteSherpaModel(_ sender: NSButton) {
        let selectedID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
            ?? SherpaModelPreset.current.id
        guard let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }),
              preset.isDownloaded else { return }

        let alert = NSAlert()
        alert.messageText = loc("asrSettings.sherpa.delete.title")
        alert.informativeText = loc("asrSettings.sherpa.delete.confirm", preset.id, preset.sizeMB)
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("asrSettings.sherpa.delete"))
        alert.addButton(withTitle: loc("common.cancel"))
        guard AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(at: preset.modelDirectory)
        } catch {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.delete.failed", error.localizedDescription)
            sherpaStatusLabel?.textColor = .systemRed
            return
        }
        // 导入预设：同步从持久化记录中移除（Imported preset: also remove its persisted record）
        if preset.isImported {
            SherpaImportedPresetStore.shared.remove(id: preset.id)
            // 当前正用着这个 preset，则切回该语言的内置默认
            // (If this was the active preset, fall back to language default)
            if UserDefaults.standard.string(forKey: "sherpaModelPresetID") == preset.id {
                UserDefaults.standard.set(SherpaModelPreset.defaultModelID(forRecognitionLanguage: preset.language), forKey: "sherpaModelPresetID")
            }
        }
        rebuildSherpaModelList()
        updateSherpaStatus()
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
            downloader.addObserver(
                progress: { [weak self] _, _, _, message in
                    self?.sherpaStatusLabel?.stringValue = message
                },
                complete: { [weak self] success, error in
                    if success {
                        self?.sherpaStatusLabel?.stringValue = loc("sherpa.download.complete")
                        self?.sherpaStatusLabel?.textColor = .systemGreen
                        self?.sherpaDownloadButton?.isEnabled = false
                        UserDefaults.standard.set(selectedID, forKey: "sherpaModelPresetID")
                        self?.rebuildSherpaModelList()
                        self?.updateSherpaStatus()
                    } else {
                        self?.sherpaStatusLabel?.stringValue = loc("sherpa.download.failed", error ?? "Unknown error")
                        self?.sherpaStatusLabel?.textColor = .systemRed
                        self?.sherpaDownloadButton?.isEnabled = true
                    }
                }
            )
            downloader.startDownload(preset: preset)
        }
    }

    @objc private func openSherpaFolder(_ sender: NSButton) {
        SherpaOnnxRecognizerController.openSupportDirectory()
    }

    @objc private func openSherpaModelList(_ sender: NSButton) {
        if let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func importSherpaModel(_ sender: NSButton) {
        let flow = SherpaModelImportFlow(parentWindow: window)
        flow.run { [weak self] record in
            guard let self else { return }
            guard let record else { return }  // 取消或失败已在 flow 内提示（cancel/failure already alerted）
            // 导入成功 → 自动选中并刷新（On success, auto-select and refresh）
            UserDefaults.standard.set(record.language, forKey: SherpaModelPreset.recognitionLanguageKey)
            UserDefaults.standard.set(record.id, forKey: "sherpaModelPresetID")
            // 同步语言下拉
            if let item = self.sherpaLanguagePopup.menu?.items.first(where: { ($0.representedObject as? String) == record.language }) {
                self.sherpaLanguagePopup.select(item)
            }
            self.rebuildSherpaModelList()
            self.updateSherpaStatus()
            self.sherpaStatusLabel?.stringValue = loc("sherpa.import.success", record.id)
            self.sherpaStatusLabel?.textColor = .systemGreen
        }
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

        // 保存 Sherpa 模型选择；如果选中的 preset 还没下载，弹窗确认是否立即下载
        // 不允许把"未下载"的 preset 静默设为 active，否则 C API 会因路径不匹配而加载失败
        // (Save Sherpa preset; if selected preset isn't downloaded, prompt to download.
        //  Don't silently activate an undownloaded preset — C API would fail to load it.)
        let selectedSherpaID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
        if let selectedID = selectedSherpaID,
           let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) {
            if !preset.isDownloaded {
                let alert = NSAlert()
                alert.messageText = loc("asrSettings.sherpa.saveUndownloaded.title")
                alert.informativeText = loc("asrSettings.sherpa.saveUndownloaded.message", preset.id, preset.sizeMB)
                alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                alert.addButton(withTitle: loc("asrSettings.sherpa.saveUndownloaded.download"))
                alert.addButton(withTitle: loc("common.cancel"))
                let result = AppDelegate.runModalAlert(alert)
                if result == .alertFirstButtonReturn {
                    defaults.set(selectedID, forKey: "sherpaModelPresetID")
                    SherpaModelDownloader.shared.startDownload(preset: preset)
                } else {
                    // 取消保存：保留旧 preset 不动（Cancel save: keep old preset unchanged）
                    statusLabel.stringValue = loc("asrSettings.sherpa.saveUndownloaded.cancelled")
                    statusLabel.textColor = .systemOrange
                    return
                }
            } else {
                defaults.set(selectedID, forKey: "sherpaModelPresetID")
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
