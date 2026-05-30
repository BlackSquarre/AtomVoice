import Cocoa

final class SherpaSettingsTab: ASRSettingsTab {
    let identifier = "sherpa"
    let label = loc("asrSettings.tab.sherpa")
    private let parentWindow: () -> NSWindow?
    private let onStatusChanged: (String, NSColor) -> Void
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    private var sherpaRadioButtons: [NSButton] = []
    private var sherpaButtonModelIDs: [NSButton: String] = [:]
    private var sherpaStatusLabel: NSTextField!
    private var sherpaDownloadButton: NSButton!
    private var sherpaDeleteButton: NSButton!
    private var sherpaLanguagePopup: NSPopUpButton!
    private var sherpaRadioStack: NSStackView!
    private var sherpaAutoUnloadCheckbox: NSButton!
    private var sherpaAutoUnloadPopup: NSPopUpButton!
    private var sherpaImportFlow: SherpaModelImportFlow?
    init(
        parentWindow: @escaping () -> NSWindow?,
        onStatusChanged: @escaping (String, NSColor) -> Void,
        sherpaDownloadReporter: SherpaDownloadReporting?
    ) {
        self.parentWindow = parentWindow
        self.onStatusChanged = onStatusChanged
        self.sherpaDownloadReporter = sherpaDownloadReporter
    }

    private func makeLabel(_ text: String, size: CGFloat, color: NSColor? = nil, wrapped: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        if let color { label.textColor = color }
        if wrapped { label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 0 }
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    private func makeStack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, alignment: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        if let alignment { stack.alignment = alignment }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    private func setSherpaStatus(_ message: String, color: NSColor) {
        sherpaStatusLabel?.stringValue = message
        sherpaStatusLabel?.textColor = color
    }
    func makeView() -> NSView {
        let view = NSView()
        let descLabel = makeLabel(loc("asrSettings.sherpa.desc"), size: 12, color: .secondaryLabelColor, wrapped: true)
        // 识别语言下拉（与 UI 语言独立）（Recognition language popup, decoupled from UI language）
        let langTitle = makeLabel(loc("asrSettings.sherpa.recognitionLanguage"), size: 13)
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
        // 计算后端选择（Compute backend selection）
        let providerTitle = makeLabel(loc("sherpa.chooser.provider"), size: 13)
        let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        let cpuItem = NSMenuItem(title: loc("sherpa.chooser.provider.cpu"), action: nil, keyEquivalent: "")
        cpuItem.representedObject = "cpu"
        providerPopup.menu?.addItem(cpuItem)
        let coremlItem = NSMenuItem(title: loc("sherpa.chooser.provider.coreml"), action: nil, keyEquivalent: "")
        coremlItem.representedObject = "coreml"
        providerPopup.menu?.addItem(coremlItem)
        if AppSettings.sherpaProvider == "coreml" {
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
        let topRow = makeStack([langTitle, sherpaLanguagePopup, spacer, providerTitle, providerPopup], orientation: .horizontal, spacing: 8, alignment: .centerY)
        // 模型列表（按"已下载/可下载"分组渲染）（Model list, grouped by downloaded/available）
        sherpaRadioStack = NSStackView()
        sherpaRadioStack.orientation = .vertical
        sherpaRadioStack.spacing = 6
        sherpaRadioStack.alignment = .leading
        sherpaRadioStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSherpaModelList()
        // 下载状态（Download status）
        sherpaStatusLabel = makeLabel("", size: 12, color: .secondaryLabelColor, wrapped: true)
        // 下载 / 删除 / 打开文件夹按钮（Download / Delete / Open folder buttons）
        sherpaDownloadButton = SettingsUI.makeButton(loc("asrSettings.sherpa.download"), target: self, action: #selector(downloadSherpaModel(_:)))
        sherpaDownloadButton.translatesAutoresizingMaskIntoConstraints = false
        sherpaDeleteButton = SettingsUI.makeButton(loc("asrSettings.sherpa.delete"), target: self, action: #selector(deleteSherpaModel(_:)))
        sherpaDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let openFolderButton = SettingsUI.makeButton(loc("menu.sherpaOpenFolder"), target: self, action: #selector(openSherpaFolder(_:)))
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = makeStack([sherpaDownloadButton, sherpaDeleteButton, openFolderButton], orientation: .horizontal, spacing: 8)
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
        let importRow = makeStack([importButton, updateRuntimeButton, importRowSpacer, githubLink], orientation: .horizontal, spacing: 8, alignment: .centerY)
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
        let autoUnloadLabel = makeLabel(loc("asrSettings.sherpa.autoUnload.after"), size: 13)
        let autoUnloadRow = makeStack([sherpaAutoUnloadCheckbox, autoUnloadLabel, sherpaAutoUnloadPopup], orientation: .horizontal, spacing: 8, alignment: .centerY)
        [descLabel, topRow, sherpaRadioStack, sherpaStatusLabel, autoUnloadRow, buttonRow, importRow].forEach(view.addSubview)
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
    func refresh() {
        rebuildSherpaModelList()
        updateSherpaAutoUnloadControls()
        updateSherpaStatus()
    }
    func save() -> ASRSettingsTabSaveOutcome {
        if let preset = selectedPreset {
            if !preset.isDownloaded {
                let alert = NSAlert()
                alert.messageText = loc("asrSettings.sherpa.saveUndownloaded.title")
                alert.informativeText = loc("asrSettings.sherpa.saveUndownloaded.message", preset.id, preset.sizeMB)
                alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                alert.addButton(withTitle: loc("asrSettings.sherpa.saveUndownloaded.download"))
                alert.addButton(withTitle: loc("common.cancel"))
                if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
                    persistSherpaAutoUnloadSettings()
                    startSherpaSettingsDownload(preset: preset, activateOnSuccess: true) { [weak self] success in
                        if success {
                            self?.onStatusChanged(loc("settings.saved"), .systemGreen)
                        }
                    }
                    onStatusChanged(loc("asrSettings.sherpa.downloading"), .systemBlue)
                    return .deferred
                } else {
                    // 取消保存：保留旧 preset 不动（Cancel save: keep old preset unchanged）
                    return .failed(message: loc("asrSettings.sherpa.saveUndownloaded.cancelled"), color: .systemOrange)
                }
            } else {
                AppSettings.sherpaModelPresetID = preset.id
            }
        }
        persistSherpaAutoUnloadSettings()
        return .saved
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
        let savedID = AppSettings.backend.string(forKey: AppSettings.Keys.sherpaModelPresetID)
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
            sherpaRadioStack.addArrangedSubview(makeLabel(loc("asrSettings.sherpa.empty"), size: 12, color: .secondaryLabelColor, wrapped: true))
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
    private var selectedModelID: String? {
        sherpaRadioButtons.first(where: { $0.state == .on }).flatMap { sherpaButtonModelIDs[$0] }
    }
    private var selectedOrCurrentModelID: String {
        selectedModelID ?? SherpaModelPreset.current.id
    }
    private var selectedPreset: SherpaModelPreset? {
        selectedModelID.flatMap { id in SherpaModelPreset.allPresets.first(where: { $0.id == id }) }
    }
    private var selectedOrCurrentPreset: SherpaModelPreset? {
        SherpaModelPreset.allPresets.first(where: { $0.id == selectedOrCurrentModelID })
    }
    private func updateSherpaStatus() {
        let preset = selectedOrCurrentPreset ?? SherpaModelPreset.current
        if preset.isDownloaded {
            setSherpaStatus(loc("asrSettings.sherpa.downloadStatus") + " ✓ " + loc("asrSettings.sherpa.downloaded"), color: .systemGreen)
            sherpaDownloadButton?.isEnabled = false
            sherpaDeleteButton?.isEnabled = true
        } else {
            setSherpaStatus(loc("asrSettings.sherpa.downloadStatus") + " " + loc("asrSettings.sherpa.notDownloaded"), color: .systemOrange)
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
        sherpaDownloadReporter?.updateProgress(message: sherpaStatusLabel.stringValue, force: false)
        let downloader = SherpaModelDownloader.shared
        downloader.addObserver(
            progress: { [weak self] _, _, _, message in
                self?.sherpaStatusLabel?.stringValue = runtimeOnly ? loc("asrSettings.sherpa.updatingRuntime") : loc("asrSettings.sherpa.downloading")
                self?.sherpaDownloadReporter?.updateProgress(message: message, force: false)
            },
            complete: { [weak self] success, error in
                guard let self else { return }
                let targetReady = runtimeOnly || preset.isDownloaded
                self.sherpaDownloadReporter?.finishDownload(success: success && targetReady, error: error)
                if success && targetReady {
                    if activateOnSuccess {
                        AppSettings.sherpaModelPresetID = preset.id
                    }
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                    self.setSherpaStatus(loc("sherpa.download.complete"), color: .systemGreen)
                } else if success {
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                } else {
                    self.rebuildSherpaModelList()
                    self.updateSherpaStatus()
                    self.setSherpaStatus(loc("sherpa.download.failed", error ?? "Unknown error"), color: .systemRed)
                }
                completion?(success && targetReady)
            }
        )

        let result = downloader.startDownload(preset: preset, forceUpdateRuntime: runtimeOnly, runtimeOnly: runtimeOnly)
        if result == .alreadyDownloading {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloading")
            sherpaDownloadReporter?.updateProgress(message: sherpaStatusLabel.stringValue, force: false)
        }
    }
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
        let savedID = AppSettings.backend.string(forKey: AppSettings.Keys.sherpaModelPresetID)
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
        guard let preset = selectedOrCurrentPreset, preset.isDownloaded else { return }
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
            setSherpaStatus(loc("asrSettings.sherpa.delete.failed", error.localizedDescription), color: .systemRed)
            return
        }
        // 导入预设：同步从持久化记录中移除（Imported preset: also remove its persisted record）
        if preset.isImported {
            SherpaImportedPresetStore.shared.remove(id: preset.id)
            // 当前正用着这个 preset，则切回该语言的内置默认
            // (If this was the active preset, fall back to language default)
            if AppSettings.backend.string(forKey: AppSettings.Keys.sherpaModelPresetID) == preset.id {
                AppSettings.sherpaModelPresetID = SherpaModelPreset.defaultModelID(forRecognitionLanguage: preset.language)
            }
        }
        rebuildSherpaModelList()
        updateSherpaStatus()
    }
    @objc private func downloadSherpaModel(_ sender: NSButton) {
        guard let preset = selectedOrCurrentPreset else { return }
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
        setSherpaStatus(loc("asrSettings.sherpa.checkingVersion"), color: .systemBlue)
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
        let preset = selectedOrCurrentPreset ?? SherpaModelPreset.current
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
        let flow = SherpaModelImportFlow(parentWindow: parentWindow())
        sherpaImportFlow = flow
        flow.run { [weak self] record in
            guard let self else { return }
            self.sherpaImportFlow = nil
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
            self.setSherpaStatus(loc("sherpa.import.success", record.id), color: .systemGreen)
        }
    }
}
