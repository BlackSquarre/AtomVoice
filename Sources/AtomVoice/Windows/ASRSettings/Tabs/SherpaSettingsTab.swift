import Cocoa

final class SherpaSettingsTab: ASRSettingsTab {
    let identifier = "sherpa"
    let label = loc("asrSettings.tab.sherpa")
    var onContentSizeChanged: (() -> Void)?
    var onBusyChanged: (() -> Void)?
    private let parentWindow: () -> NSWindow?
    private let onStatusChanged: (String, NSColor) -> Void
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    private let operatingSystemVersion: OperatingSystemVersion
    private struct SavedFields: Equatable {
        let modelID: String?
        let unload: Bool
        let minutes: Int
    }
    private var baseline: SavedFields?
    private var fields: SavedFields {
        .init(modelID: selectedModelID, unload: sherpaAutoUnloadCheckbox?.state == .on,
              minutes: (sherpaAutoUnloadPopup?.selectedItem?.representedObject as? Int) ?? 15)
    }
    var hasChanges: Bool { baseline != nil && fields != baseline }
    func refreshStatus() {
        requestInventoryRefresh()
        updateSherpaStatus()
    }
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
    private var sherpaImportButton: NSButton!
    private var sherpaRuntimeButton: NSButton!
    private var draftModelID: String?
    private var inventory: [SherpaModelInventory.Entry] = []
    private var inventoryLanguage: String?
    private var inventoryGeneration = 0
    private var inventoryScheduled = false
    private var inventoryLoading = false
    private var inventoryNeedsRefresh = false
    private let inventoryQueue = DispatchQueue(label: "AtomVoice.SherpaSettings.inventory", qos: .userInitiated)
    private var resourceObserver: NSObjectProtocol?
    private var downloadObserver: NSObjectProtocol?
    private enum Operation { case importing, deleting, checkingRuntime }
    private var operation: Operation?
    init(
        parentWindow: @escaping () -> NSWindow?,
        onStatusChanged: @escaping (String, NSColor) -> Void,
        sherpaDownloadReporter: SherpaDownloadReporting?,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.parentWindow = parentWindow
        self.onStatusChanged = onStatusChanged
        self.sherpaDownloadReporter = sherpaDownloadReporter
        self.operatingSystemVersion = operatingSystemVersion
        resourceObserver = NotificationCenter.default.addObserver(forName: .sherpaResourcesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.requestInventoryRefresh(invalidate: true)
        }
        downloadObserver = NotificationCenter.default.addObserver(forName: .sherpaDownloadStateDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.sherpaRadioStack != nil else { return }
            self.updateSherpaStatus()
            if !SherpaModelDownloader.shared.isDownloading { self.requestInventoryRefresh(invalidate: true) }
        }
    }

    deinit {
        if let resourceObserver { NotificationCenter.default.removeObserver(resourceObserver) }
        if let downloadObserver { NotificationCenter.default.removeObserver(downloadObserver) }
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
        let view = SherpaSettingsDocumentView()
        let descLabel = makeLabel(loc("asrSettings.sherpa.desc"), size: 12, color: .secondaryLabelColor, wrapped: true)
        let compatibility = makeLabel(SherpaRuntimeRelease.compatibilityNotice(on: operatingSystemVersion) ?? "",
                                      size: 12, color: .secondaryLabelColor, wrapped: true)
        compatibility.identifier = NSUserInterfaceItemIdentifier("sherpa.runtime.compatibility")
        compatibility.isHidden = !SherpaRuntimeRelease.requiresVersionRestriction(on: operatingSystemVersion)
        let header = makeStack([descLabel, compatibility], orientation: .vertical, spacing: 8, alignment: .leading)
        header.identifier = NSUserInterfaceItemIdentifier("sherpa.settings.header")
        descLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        compatibility.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
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
        topRow.identifier = NSUserInterfaceItemIdentifier("sherpa.settings.controls")
        // 模型列表（按"已下载/可下载"分组渲染）（Model list, grouped by downloaded/available）
        sherpaRadioStack = NSStackView()
        sherpaRadioStack.orientation = .vertical
        sherpaRadioStack.spacing = 6
        sherpaRadioStack.alignment = .leading
        sherpaRadioStack.translatesAutoresizingMaskIntoConstraints = false
        sherpaRadioStack.identifier = NSUserInterfaceItemIdentifier("sherpa.settings.models")
        draftModelID = SherpaModelPreset.current.id
        renderModelList()
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
        sherpaImportButton = importButton
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.toolTip = loc("asrSettings.sherpa.import.tooltip")
        let updateRuntimeButton = SettingsUI.makeButton(loc("asrSettings.sherpa.updateRuntime"), target: self, action: #selector(updateSherpaRuntime(_:)))
        sherpaRuntimeButton = updateRuntimeButton
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
        [header, topRow, sherpaRadioStack, sherpaStatusLabel, autoUnloadRow, buttonRow, importRow].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
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
        baseline = fields
        requestInventoryRefresh()
        updateSherpaStatus()
        // 文档按内容决定高度，短页面的余量留在底部，避免拉伸说明区。
        // 旧系统说明、多语言和较长模型列表可滚动查看，不挤压下方操作按钮。
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
        return scroll
    }
    func refresh() {
        draftModelID = SherpaModelPreset.current.id
        renderModelList()
        updateSherpaAutoUnloadControls()
        requestInventoryRefresh()
        updateSherpaStatus()
        baseline = fields
    }
    func save() -> ASRSettingsTabSaveOutcome {
        guard !isBusy else { updateSherpaStatus(); return .deferred }
        guard inventoryLanguage == SherpaModelPreset.recognitionLanguage else {
            requestInventoryRefresh()
            return .failed(message: loc("settings.loading"), color: .secondaryLabelColor)
        }
        guard hasChanges else { return .saved }
        let submitted = fields
        if let preset = selectedPreset {
            if !isDownloaded(preset.id) {
                persistSherpaAutoUnloadSettings()
                baseline = .init(modelID: baseline?.modelID, unload: submitted.unload, minutes: submitted.minutes)
                startSherpaSettingsDownload(preset: preset, activateOnSuccess: true)
                onStatusChanged(loc("asrSettings.sherpa.downloading"), .systemBlue)
                return .deferred
            } else {
                SherpaModelSelection.shared.selectPreset(preset.id)
            }
        }
        persistSherpaAutoUnloadSettings()
        baseline = fields
        return .saved
    }
    /// 按当前识别语言重建模型列表，已下载组在前
    /// (Rebuild model list under current recognition language, downloaded group first)
    private func renderModelList() {
        guard sherpaRadioStack != nil else { return }
        sherpaRadioStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sherpaRadioButtons = []
        sherpaButtonModelIDs = [:]
        let lang = SherpaModelPreset.recognitionLanguage
        let entries = inventoryLanguage == lang ? inventory : []
        let presets = entries.map(\.preset)
        let downloaded = entries.filter(\.isDownloaded).map(\.preset)
        let pending = entries.filter { !$0.isDownloaded }.map(\.preset)
        // 当前选择的 preset id：若已不在当前语言列表中则回退到该语言的默认
        // (Current preset id; fall back to language default if it's not in this language's list)
        let savedID = AppSettings.backend.string(forKey: AppSettings.Keys.sherpaModelPresetID)
        let validIDs = Set(presets.map { $0.id })
        let activeID = (draftModelID ?? savedID).flatMap { validIDs.contains($0) ? $0 : nil }
            ?? SherpaModelPreset.defaultModelID(forRecognitionLanguage: lang)
        if inventoryLanguage == lang { draftModelID = activeID }

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
            let key = inventoryLanguage == lang ? "asrSettings.sherpa.empty" : "settings.loading"
            sherpaRadioStack.addArrangedSubview(makeLabel(loc(key), size: 12, color: .secondaryLabelColor, wrapped: true))
        }
        onContentSizeChanged?()
    }

    /// 同一轮主循环的刷新合并为一次读取；资源变化使正在读取的旧结果失效。
    private func requestInventoryRefresh(invalidate: Bool = false) {
        guard sherpaRadioStack != nil else { return }
        if inventoryLoading {
            if invalidate { inventoryGeneration += 1; inventoryNeedsRefresh = true }
            return
        }
        guard !inventoryScheduled else { return }
        inventoryScheduled = true
        DispatchQueue.main.async { [weak self] in self?.loadInventory() }
    }

    private func loadInventory() {
        inventoryScheduled = false
        inventoryLoading = true
        inventoryGeneration += 1
        let generation = inventoryGeneration
        let language = SherpaModelPreset.recognitionLanguage
        let presets = SherpaModelPreset.presets(forRecognitionLanguage: language)
        inventoryQueue.async { [weak self] in
            let result = SherpaModelInventory.scan(presets: presets)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inventoryLoading = false
                if self.inventoryGeneration == generation, SherpaModelPreset.recognitionLanguage == language {
                    self.inventory = result
                    self.inventoryLanguage = language
                    self.renderModelList()
                    self.updateSherpaStatus()
                }
                if self.inventoryNeedsRefresh || SherpaModelPreset.recognitionLanguage != language {
                    self.inventoryNeedsRefresh = false
                    self.requestInventoryRefresh()
                }
            }
        }
    }

    private func isDownloaded(_ modelID: String) -> Bool {
        inventory.first { $0.preset.id == modelID }?.isDownloaded == true
    }

    var isBusy: Bool { operation != nil || SherpaModelDownloader.shared.isDownloading }
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
        draftModelID
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
        onBusyChanged?()
        guard sherpaStatusLabel != nil else { return }
        let preset = selectedOrCurrentPreset ?? SherpaModelPreset.current
        let ready = isDownloaded(preset.id)
        let hasInventory = inventoryLanguage == SherpaModelPreset.recognitionLanguage
        sherpaDownloadButton?.isEnabled = !isBusy && hasInventory && !ready && !preset.isImported
        sherpaDeleteButton?.isEnabled = !isBusy && hasInventory && ready
        sherpaImportButton?.isEnabled = !isBusy
        sherpaRuntimeButton?.isEnabled = !isBusy
        // 导入/删除确认后固定本页目标；下载期间仍允许保留后来的模型草稿。
        sherpaLanguagePopup?.isEnabled = operation == nil
        sherpaRadioButtons.forEach { $0.isEnabled = operation == nil }
        if let operation {
            let key: String
            switch operation {
            case .importing: key = "asrSettings.sherpa.importing"
            case .deleting: key = "asrSettings.sherpa.deleting"
            case .checkingRuntime: key = "asrSettings.sherpa.checkingVersion"
            }
            setSherpaStatus(loc(key), color: .systemBlue)
        } else if SherpaModelDownloader.shared.isDownloading {
            setSherpaStatus(loc("asrSettings.sherpa.downloading"), color: .systemBlue)
        } else if !hasInventory {
            setSherpaStatus(loc("settings.loading"), color: .secondaryLabelColor)
        } else if ready {
            setSherpaStatus(loc("asrSettings.sherpa.downloadStatus") + " ✓ " + loc("asrSettings.sherpa.downloaded"), color: .systemGreen)
        } else {
            setSherpaStatus(loc("asrSettings.sherpa.downloadStatus") + " " + loc("asrSettings.sherpa.notDownloaded"), color: .systemOrange)
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
        runtimeRelease: SherpaRuntimeRelease? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isBusy else { updateSherpaStatus(); completion?(false); return }
        sherpaDownloadButton?.isEnabled = false
        sherpaDeleteButton?.isEnabled = false
        sherpaStatusLabel?.stringValue = runtimeOnly ? loc("asrSettings.sherpa.updatingRuntime") : loc("asrSettings.sherpa.downloading")
        sherpaStatusLabel?.textColor = .systemBlue
        sherpaDownloadReporter?.updateProgress(progress: 0, message: sherpaStatusLabel.stringValue, force: false)
        let selectionWhenRequested = selectedModelID
        let coordinator = SherpaDownloadCoordinator(downloader: .shared, reporter: sherpaDownloadReporter)
        let result = coordinator.start(preset: preset, runtimeOnly: runtimeOnly, activateOnSuccess: activateOnSuccess,
            runtimeRelease: runtimeRelease,
            progress: { [weak self] _ in
                self?.sherpaStatusLabel?.stringValue = runtimeOnly ? loc("asrSettings.sherpa.updatingRuntime") : loc("asrSettings.sherpa.downloading")
            }, completion: { [weak self] success, error in
                guard let self else { return }
                let preserveLaterDraft = self.selectedModelID != selectionWhenRequested
                if success && activateOnSuccess, let old = self.baseline {
                    self.baseline = .init(modelID: preset.id, unload: old.unload, minutes: old.minutes)
                }
                if success && activateOnSuccess && !preserveLaterDraft { self.draftModelID = preset.id }
                self.requestInventoryRefresh(invalidate: true)
                self.updateSherpaStatus()
                let key = success
                    ? (runtimeOnly ? "sherpa.runtime.download.complete" : "sherpa.download.complete")
                    : (runtimeOnly ? "sherpa.runtime.download.failed" : "sherpa.download.failed")
                self.setSherpaStatus(success ? loc(key) : loc(key, error ?? "Unknown error"), color: success ? .systemGreen : .systemRed)
                completion?(success)
            })
        if result == .alreadyDownloading {
            sherpaStatusLabel?.stringValue = loc("asrSettings.sherpa.downloading")
            sherpaDownloadReporter?.updateProgress(progress: 0, message: sherpaStatusLabel.stringValue, force: false)
            if runtimeOnly { completion?(false) }
        }
    }
    @objc private func sherpaModelSelected(_ sender: NSButton) {
        guard let modelID = sherpaButtonModelIDs[sender] else { return }
        draftModelID = modelID
        for radio in sherpaRadioButtons {
            radio.state = sherpaButtonModelIDs[radio] == modelID ? .on : .off
        }
        updateSherpaStatus()
    }
    @objc private func sherpaLanguageChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let code = item.representedObject as? String else { return }
        SherpaModelSelection.shared.changeLanguage(code)
        draftModelID = SherpaModelPreset.current.id
        renderModelList()
        requestInventoryRefresh(invalidate: true)
        if let old = baseline {
            baseline = .init(modelID: selectedModelID, unload: old.unload, minutes: old.minutes)
        }
        updateSherpaStatus()
    }
    @objc private func sherpaProviderChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let provider = item.representedObject as? String else { return }
        SherpaModelSelection.shared.selectProvider(provider)
    }
    @objc private func sherpaAutoUnloadChanged(_ sender: NSButton) {
        sherpaAutoUnloadPopup?.isEnabled = sender.state == .on
    }
    @objc private func deleteSherpaModel(_ sender: NSButton) {
        guard !isBusy else { updateSherpaStatus(); return }
        guard let preset = selectedOrCurrentPreset, isDownloaded(preset.id) else { return }
        let alert = NSAlert()
        alert.messageText = loc("asrSettings.sherpa.delete.title")
        alert.informativeText = loc("asrSettings.sherpa.delete.confirm", preset.id, preset.sizeMB)
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("asrSettings.sherpa.delete"))
        alert.addButton(withTitle: loc("common.cancel"))
        guard AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn else { return }
        // 确认弹窗运行期间其他入口可能开始下载，需要再次检查。
        guard !isBusy else { updateSherpaStatus(); return }
        operation = .deleting
        updateSherpaStatus()
        SherpaResourceInstaller.removeModelAsync(preset) { [weak self] result in
            guard let self else { return }
            self.operation = nil
            if case .failure(let error) = result {
                self.updateSherpaStatus()
                self.setSherpaStatus(loc("asrSettings.sherpa.delete.failed", error.localizedDescription), color: .systemRed)
            } else {
                if self.draftModelID == preset.id, preset.isImported {
                    self.draftModelID = SherpaModelPreset.current.id
                    if let old = self.baseline {
                        self.baseline = .init(modelID: self.draftModelID, unload: old.unload, minutes: old.minutes)
                    }
                }
                self.requestInventoryRefresh(invalidate: true)
                self.updateSherpaStatus()
            }
        }
    }
    @objc private func downloadSherpaModel(_ sender: NSButton) {
        guard let preset = selectedOrCurrentPreset else { return }
        startSherpaSettingsDownload(preset: preset, activateOnSuccess: true)
    }
    @objc private func updateSherpaRuntime(_ sender: NSButton) {
        guard !isBusy else { updateSherpaStatus(); return }
        operation = .checkingRuntime
        updateSherpaStatus()
        // 1. 检查版本 (Check version)
        setSherpaStatus(loc("asrSettings.sherpa.checkingVersion"), color: .systemBlue)
        SherpaModelDownloader.fetchLatestRuntimeRelease { [weak self] result in
            guard let self = self else { return }
            let currentVersion = SherpaModelDownloader.getLocalRuntimeVersion()
            DispatchQueue.main.async {
                guard case .success(let release) = result else {
                    self.operation = nil
                    self.updateSherpaStatus()
                    self.setSherpaStatus(loc("sherpa.runtime.error.releaseMetadata"), color: .systemRed)
                    return
                }
                let latestVersion = release.version
                guard !SherpaModelDownloader.shared.isDownloading else {
                    self.operation = nil
                    self.updateSherpaStatus()
                    return
                }
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
                    self.operation = nil
                    self.performRuntimeUpdate(sender: sender, release: release)
                } else {
                    self.operation = nil
                    self.updateSherpaStatus()
                }
            }
        }
    }
    private func performRuntimeUpdate(sender: NSButton, release: SherpaRuntimeRelease) {
        let preset = selectedOrCurrentPreset ?? SherpaModelPreset.current
        startSherpaSettingsDownload(preset: preset, activateOnSuccess: false, runtimeOnly: true, runtimeRelease: release) { [weak sender] _ in
            sender?.isEnabled = !SherpaModelDownloader.shared.isDownloading
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
        guard !isBusy, sherpaImportFlow == nil else { updateSherpaStatus(); return }
        let flow = SherpaModelImportFlow(parentWindow: parentWindow())
        sherpaImportFlow = flow
        operation = .importing
        updateSherpaStatus()
        flow.run { [weak self] record in
            guard let self, self.sherpaImportFlow === flow else { return }
            self.sherpaImportFlow = nil
            self.operation = nil
            self.updateSherpaStatus()
            guard let record else { return }  // 取消或失败已在 flow 内提示（cancel/failure already alerted）
            // 导入成功 → 自动选中并刷新（On success, auto-select and refresh）
            SherpaModelSelection.shared.select(language: record.language, presetID: record.id)
            // 同步语言下拉（Sync language popup）
            if let item = self.sherpaLanguagePopup.menu?.items.first(where: { ($0.representedObject as? String) == record.language }) {
                self.sherpaLanguagePopup.select(item)
            }
            if let old = self.baseline {
                self.baseline = .init(modelID: record.id, unload: old.unload, minutes: old.minutes)
            }
            self.draftModelID = record.id
            self.requestInventoryRefresh(invalidate: true)
            self.updateSherpaStatus()
            self.setSherpaStatus(loc("sherpa.import.success", record.id), color: .systemGreen)
        }
    }
}

private final class SherpaSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
