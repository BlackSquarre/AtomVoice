import Cocoa

final class ASRSettingsWindowController: NSObject {
    private static let initialContentSize = NSSize(width: 640, height: 600)

    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var tabView: NSTabView!

    // Sherpa 设置（Sherpa settings）
    private var sherpaRadioButtons: [NSButton] = []
    private var sherpaButtonModelIDs: [NSButton: String] = [:]
    private var sherpaStatusLabel: NSTextField!
    private var sherpaDownloadButton: NSButton!
    private var sherpaDeleteButton: NSButton!
    private var sherpaLanguagePopup: NSPopUpButton!
    private var sherpaRadioStack: NSStackView!
    private var sherpaAutoUnloadCheckbox: NSButton!
    private var sherpaAutoUnloadPopup: NSPopUpButton!

    private let appleTab = AppleSettingsTab()
    private lazy var doubaoTab = DoubaoSettingsTab(textFieldDelegate: self)

    // 状态（Status）
    private var statusLabel: NSTextField!

    func showWindow() {
        if let window {
            refreshFields()
            WindowPresenter.shared.bringToFront(window)
            return
        }
        buildWindow()
    }

    #if DEBUG_BUILD
    func showWindowForSnapshot(tabIdentifier: String) {
        if window == nil {
            buildWindow()
        }
        selectTab(identifier: tabIdentifier)
        window?.setContentSize(Self.initialContentSize)
        window?.makeKeyAndOrderFront(nil)
    }
    #endif

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("asrSettings.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 600, height: 520)

        guard let cv = w.contentView else { return }
        let pad: CGFloat = 24

        // 创建 TabView（Create TabView）
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        // 标签页 1：Sherpa 本地识别（Tab 1: Sherpa local recognition）
        let sherpaTab = NSTabViewItem(identifier: "sherpa")
        sherpaTab.label = loc("asrSettings.tab.sherpa")
        sherpaTab.view = buildSherpaTab()
        tabView.addTabViewItem(sherpaTab)

        // 标签页 2：Apple 离线识别（Tab 2: Apple offline recognition）
        let appleTab = NSTabViewItem(identifier: "apple")
        appleTab.label = loc("asrSettings.tab.apple")
        appleTab.view = self.appleTab.makeView()
        tabView.addTabViewItem(appleTab)

        // 标签页 3：豆包云端识别（Tab 3: Doubao cloud recognition）
        let doubaoTab = NSTabViewItem(identifier: "doubao")
        doubaoTab.label = loc("asrSettings.tab.doubao")
        doubaoTab.view = self.doubaoTab.makeView()
        tabView.addTabViewItem(doubaoTab)

        // 底部按钮（Bottom buttons）
        statusLabel = SettingsUI.makeSecondaryLabel()

        let cancelBtn = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let saveBtn = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [cancelBtn, saveBtn])

        // 布局（Layout）
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
        let currentEngine = AppSettings.normalizedRecognitionEngine
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

        w.setContentSize(Self.initialContentSize)
        w.center()
        w.recalculateKeyViewLoop()
        WindowPresenter.shared.bringToFront(w)
    }

    private func selectTab(identifier: String) {
        let tabIndex = tabView.indexOfTabViewItem(withIdentifier: identifier)
        if tabIndex != NSNotFound {
            tabView.selectTabViewItem(at: tabIndex)
        }
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

        // 计算后端选择（Compute backend selection）
        let providerTitle = NSTextField(labelWithString: loc("sherpa.chooser.provider"))
        providerTitle.font = .systemFont(ofSize: 13)
        providerTitle.translatesAutoresizingMaskIntoConstraints = false

        let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        let cpuItem = NSMenuItem(title: loc("sherpa.chooser.provider.cpu"), action: nil, keyEquivalent: "")
        cpuItem.representedObject = "cpu"
        providerPopup.menu?.addItem(cpuItem)
        let coremlItem = NSMenuItem(title: loc("sherpa.chooser.provider.coreml"), action: nil, keyEquivalent: "")
        coremlItem.representedObject = "coreml"
        providerPopup.menu?.addItem(coremlItem)
        let currentProvider = AppSettings.sherpaProvider
        if currentProvider == "coreml" {
            providerPopup.select(coremlItem)
        } else {
            providerPopup.select(cpuItem)
        }
        providerPopup.target = self
        providerPopup.action = #selector(sherpaProviderChanged(_:))

        // 把语言和后端选择放在同一行，后端右对齐（Place language and backend controls on one row, right-aligning the backend）
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [langTitle, sherpaLanguagePopup, spacer, providerTitle, providerPopup])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // 模型列表（按"已下载/可下载"分组渲染）（Model list, grouped by downloaded/available）
        sherpaRadioStack = NSStackView()
        sherpaRadioStack.orientation = .vertical
        sherpaRadioStack.spacing = 6
        sherpaRadioStack.alignment = .leading
        sherpaRadioStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSherpaModelList()

        // 下载状态（Download status）
        sherpaStatusLabel = NSTextField(labelWithString: "")
        sherpaStatusLabel.font = .systemFont(ofSize: 12)
        sherpaStatusLabel.textColor = .secondaryLabelColor
        sherpaStatusLabel.lineBreakMode = .byWordWrapping
        sherpaStatusLabel.maximumNumberOfLines = 0
        sherpaStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 下载 / 删除 / 打开文件夹按钮（Download / Delete / Open folder buttons）
        sherpaDownloadButton = SettingsUI.makeButton(loc("asrSettings.sherpa.download"), target: self, action: #selector(downloadSherpaModel(_:)))
        sherpaDownloadButton.translatesAutoresizingMaskIntoConstraints = false

        sherpaDeleteButton = SettingsUI.makeButton(loc("asrSettings.sherpa.delete"), target: self, action: #selector(deleteSherpaModel(_:)))
        sherpaDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let openFolderButton = SettingsUI.makeButton(loc("menu.sherpaOpenFolder"), target: self, action: #selector(openSherpaFolder(_:)))
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [sherpaDownloadButton, sherpaDeleteButton, openFolderButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // 第二行：导入模型包 + 指向 sherpa-onnx 模型列表的链接
        // (Second row: import button + link to sherpa-onnx model list)
        let importButton = SettingsUI.makeButton(loc("asrSettings.sherpa.import"), target: self, action: #selector(importSherpaModel(_:)))
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.toolTip = loc("asrSettings.sherpa.import.tooltip")

        let updateRuntimeButton = SettingsUI.makeButton(loc("asrSettings.sherpa.updateRuntime"), target: self, action: #selector(updateSherpaRuntime(_:)))
        updateRuntimeButton.translatesAutoresizingMaskIntoConstraints = false

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

        let importRow = NSStackView(views: [importButton, updateRuntimeButton, importRowSpacer, githubLink])
        importRow.orientation = .horizontal
        importRow.spacing = 8
        importRow.alignment = .centerY
        importRow.translatesAutoresizingMaskIntoConstraints = false

        sherpaAutoUnloadCheckbox = SettingsUI.makeCheckbox(
            title: loc("asrSettings.sherpa.autoUnload"),
            tooltip: loc("asrSettings.sherpa.autoUnload.tooltip")
        )
        sherpaAutoUnloadCheckbox.target = self
        sherpaAutoUnloadCheckbox.action = #selector(sherpaAutoUnloadChanged(_:))
        sherpaAutoUnloadCheckbox.translatesAutoresizingMaskIntoConstraints = false

        sherpaAutoUnloadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sherpaAutoUnloadPopup.translatesAutoresizingMaskIntoConstraints = false
        for minutes in AppSettings.sherpaAutoUnloadMinuteOptions {
            let item = NSMenuItem(
                title: String(format: loc("asrSettings.sherpa.autoUnload.minutes"), minutes),
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = minutes
            sherpaAutoUnloadPopup.menu?.addItem(item)
        }

        let autoUnloadLabel = NSTextField(labelWithString: loc("asrSettings.sherpa.autoUnload.after"))
        autoUnloadLabel.font = .systemFont(ofSize: 13)
        autoUnloadLabel.translatesAutoresizingMaskIntoConstraints = false

        let autoUnloadRow = NSStackView(views: [sherpaAutoUnloadCheckbox, autoUnloadLabel, sherpaAutoUnloadPopup])
        autoUnloadRow.orientation = .horizontal
        autoUnloadRow.spacing = 8
        autoUnloadRow.alignment = .centerY
        autoUnloadRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(descLabel)
        view.addSubview(topRow)
        view.addSubview(sherpaRadioStack)
        view.addSubview(sherpaStatusLabel)
        view.addSubview(autoUnloadRow)
        view.addSubview(buttonRow)
        view.addSubview(importRow)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            topRow.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sherpaRadioStack.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 12),
            sherpaRadioStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            sherpaRadioStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sherpaStatusLabel.topAnchor.constraint(equalTo: sherpaRadioStack.bottomAnchor, constant: 12),
            sherpaStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sherpaStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            autoUnloadRow.topAnchor.constraint(equalTo: sherpaStatusLabel.bottomAnchor, constant: 12),
            autoUnloadRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            buttonRow.topAnchor.constraint(equalTo: autoUnloadRow.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            importRow.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            importRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            importRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            importRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        updateSherpaAutoUnloadControls()
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
        let savedID = UserDefaults.standard.string(forKey: AppSettings.Keys.sherpaModelPresetID)
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
        AppSettings.displayName(forRecognitionLanguage: code)
    }

    // MARK: - 辅助方法（Helper methods）

    private func refreshFields() {
        // 豆包设置（Doubao settings）
        doubaoTab.refresh()

        // Sherpa 设置（Sherpa settings）
        rebuildSherpaModelList()
        updateSherpaAutoUnloadControls()
        updateSherpaStatus()

        // Apple 设置（Apple settings）
        appleTab.refresh()

        // 状态（Status）
        statusLabel?.stringValue = ""
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

    private func updateSherpaAutoUnloadControls() {
        let enabled = AppSettings.sherpaAutoUnloadEnabled
        sherpaAutoUnloadCheckbox?.state = enabled ? .on : .off

        let minutes = AppSettings.sherpaAutoUnloadIdleMinutes
        if let item = sherpaAutoUnloadPopup?.itemArray.first(where: { ($0.representedObject as? Int) == minutes }) {
            sherpaAutoUnloadPopup?.select(item)
        } else {
            sherpaAutoUnloadPopup?.selectItem(at: 0)
        }
        sherpaAutoUnloadPopup?.isEnabled = enabled
    }



    private func persistSherpaAutoUnloadSettings() {
        AppSettings.sherpaAutoUnloadEnabled = sherpaAutoUnloadCheckbox.state == .on
        let selectedUnloadMinutes = (sherpaAutoUnloadPopup.selectedItem?.representedObject as? Int) ?? 15
        AppSettings.sherpaAutoUnloadIdleMinutes = selectedUnloadMinutes
    }



    private func startSherpaSettingsDownload(
        preset: SherpaModelPreset,
        activateOnSuccess: Bool,
        runtimeOnly: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        sherpaDownloadButton?.isEnabled = false
        sherpaDeleteButton?.isEnabled = false
        sherpaStatusLabel?.stringValue = runtimeOnly ? loc("asrSettings.sherpa.updatingRuntime") : loc("asrSettings.sherpa.downloading")
        sherpaStatusLabel?.textColor = .systemBlue
        AppDelegate.showSherpaDownloadCapsule(sherpaStatusLabel.stringValue)

        let downloader = SherpaModelDownloader.shared
        downloader.addObserver(
            progress: { [weak self] _, _, _, message in
                self?.sherpaStatusLabel?.stringValue = runtimeOnly ? loc("asrSettings.sherpa.updatingRuntime") : loc("asrSettings.sherpa.downloading")
                AppDelegate.showSherpaDownloadCapsule(message)
            },
            complete: { [weak self] success, error in
                guard let self else { return }
                let targetReady = runtimeOnly || preset.isDownloaded
                AppDelegate.finishSherpaDownloadCapsule(success: success && targetReady, error: error)
                if success && targetReady {
                    if activateOnSuccess {
                        AppSettings.sherpaModelPresetID = preset.id
                    }
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                    self.sherpaStatusLabel?.stringValue = loc("sherpa.download.complete")
                    self.sherpaStatusLabel?.textColor = .systemGreen
                } else if success {
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                } else {
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                    self.sherpaStatusLabel?.stringValue = loc("sherpa.download.failed", error ?? "Unknown error")
                    self.sherpaStatusLabel?.textColor = .systemRed
                }
                completion?(success && targetReady)
            }
        )

        let result = downloader.startDownload(preset: preset, forceUpdateRuntime: runtimeOnly, runtimeOnly: runtimeOnly)
        if result == .alreadyDownloading {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloading")
            AppDelegate.showSherpaDownloadCapsule(sherpaStatusLabel.stringValue)
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
        AppSettings.sherpaRecognitionLanguage = code
        // 切换语言后，若当前 preset 不在新语言列表中，自动切到该语言默认模型
        // (After language switch, if current preset isn't in new list, auto-select language default)
        let presets = SherpaModelPreset.presets(forRecognitionLanguage: code)
        let savedID = UserDefaults.standard.string(forKey: AppSettings.Keys.sherpaModelPresetID)
        if savedID == nil || !presets.contains(where: { $0.id == savedID }) {
            AppSettings.sherpaModelPresetID = SherpaModelPreset.defaultModelID(forRecognitionLanguage: code)
        }
        rebuildSherpaModelList()
        updateSherpaStatus()
    }

    @objc private func sherpaProviderChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let provider = item.representedObject as? String else { return }
        AppSettings.sherpaProvider = provider
    }

    @objc private func sherpaAutoUnloadChanged(_ sender: NSButton) {
        sherpaAutoUnloadPopup?.isEnabled = sender.state == .on
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
        guard AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn else { return }

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
            if UserDefaults.standard.string(forKey: AppSettings.Keys.sherpaModelPresetID) == preset.id {
                AppSettings.sherpaModelPresetID = SherpaModelPreset.defaultModelID(forRecognitionLanguage: preset.language)
            }
        }
        rebuildSherpaModelList()
        updateSherpaStatus()
    }

    @objc private func downloadSherpaModel(_ sender: NSButton) {
        // 获取选中的模型 ID（Get selected model ID）
        let selectedID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] } ?? SherpaModelPreset.current.id
        guard let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) else { return }

        // 确认下载（Confirm download）
        let alert = NSAlert()
        alert.messageText = loc("sherpa.download.title")
        alert.informativeText = loc("asrSettings.sherpa.download.confirm")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("sherpa.download.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))

        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
            startSherpaSettingsDownload(preset: preset, activateOnSuccess: true)
        }
    }

    @objc private func updateSherpaRuntime(_ sender: NSButton) {
        guard !SherpaModelDownloader.shared.isDownloading else { return }
        
        sender.isEnabled = false
        sherpaDownloadButton?.isEnabled = false
        sherpaDeleteButton?.isEnabled = false
        
        // 1. 检查版本 (Check version)
        sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.checkingVersion")
        sherpaStatusLabel?.textColor = .systemBlue
        
        SherpaModelDownloader.fetchLatestRuntimeVersion { [weak self] latestVersion in
            guard let self = self else { return }
            let currentVersion = SherpaModelDownloader.getLocalRuntimeVersion()
            
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = loc("sherpa.update.title")
                if latestVersion == currentVersion {
                    alert.informativeText = loc("sherpa.update.message.same", currentVersion)
                } else {
                    alert.informativeText = loc("sherpa.update.message.new", latestVersion, currentVersion)
                }
                alert.icon = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil)
                alert.addButton(withTitle: loc("common.ok"))
                alert.addButton(withTitle: loc("common.cancel"))
                
                if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
                    self.performRuntimeUpdate(sender: sender)
                } else {
                    sender.isEnabled = true
                    self.updateSherpaStatus()
                    self.rebuildSherpaModelList()
                }
            }
        }
    }

    private func performRuntimeUpdate(sender: NSButton) {
        let selectedID = sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
            ?? SherpaModelPreset.current.id
        let preset = SherpaModelPreset.allPresets.first(where: { $0.id == selectedID }) ?? SherpaModelPreset.current
        startSherpaSettingsDownload(preset: preset, activateOnSuccess: false, runtimeOnly: true) { [weak sender] _ in
            sender?.isEnabled = true
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
            AppSettings.sherpaRecognitionLanguage = record.language
            AppSettings.sherpaModelPresetID = record.id
            // 同步语言下拉（Sync language popup）
            if let item = self.sherpaLanguagePopup.menu?.items.first(where: { ($0.representedObject as? String) == record.language }) {
                self.sherpaLanguagePopup.select(item)
            }
            self.rebuildSherpaModelList()
            self.updateSherpaStatus()
            self.sherpaStatusLabel?.stringValue = loc("sherpa.import.success", record.id)
            self.sherpaStatusLabel?.textColor = .systemGreen
        }
    }





    @objc private func saveSettings(_ sender: NSButton) {
        // 保存豆包设置（Save Doubao settings）
        switch doubaoTab.save() {
        case .saved, .deferred:
            break
        case let .failed(message, color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
            return
        }

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
                let result = AlertPresenter.shared.runModalAlert(alert)
                if result == .alertFirstButtonReturn {
                    persistSherpaAutoUnloadSettings()
                    _ = appleTab.save()
                    startSherpaSettingsDownload(preset: preset, activateOnSuccess: true) { [weak self] success in
                        if success {
                            self?.statusLabel.stringValue = loc("settings.saved")
                            self?.statusLabel.textColor = .systemGreen
                        }
                    }
                    statusLabel.stringValue = loc("asrSettings.sherpa.downloading")
                    statusLabel.textColor = .systemBlue
                    return
                } else {
                    // 取消保存：保留旧 preset 不动（Cancel save: keep old preset unchanged）
                    statusLabel.stringValue = loc("asrSettings.sherpa.saveUndownloaded.cancelled")
                    statusLabel.textColor = .systemOrange
                    return
                }
            } else {
                AppSettings.sherpaModelPresetID = selectedID
            }
        }
        persistSherpaAutoUnloadSettings()

        // 保存 Apple 设置（Save Apple settings）
        switch appleTab.save() {
        case .saved, .deferred:
            break
        case let .failed(message, color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
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

// MARK: - NSTabViewDelegate

extension ASRSettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // 标签页切换时刷新（Refresh when switching tabs）
        refreshFields()
    }
}

// MARK: - NSWindowDelegate

extension ASRSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
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
