import Cocoa
import ServiceManagement

/// 设置主窗口只组织轻量控件；引擎、模型、钥匙串和输入会话仍由既有 owner 管理。
final class UnifiedSettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let preferredContentWidth: CGFloat = 470

    enum Page: String, CaseIterable {
        case general, input, mode, appearance, permissions, about
        var section: String {
            switch self { case .general: return "general"; case .input, .mode: return "voice"; case .appearance: return "appearance"; case .permissions, .about: return "system" }
        }
        var title: String {
            switch self {
            case .general: return loc("preferences.page.general")
            case .input: return loc("menu.inputMode")
            case .mode: return loc("menu.recognitionEngine")
            case .appearance: return loc("preferences.page.appearance")
            case .permissions: return loc("preferences.page.permissions")
            case .about: return loc("preferences.page.about")
            }
        }
    }
    var onTriggerChanged: ((UInt16) -> Void)?
    var onHeadphoneChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onSelectEngine: ((String) -> Void)?
    #if DEBUG_BUILD
    var makeDebugToolsMenu: (() -> NSMenu)?
    #endif
    private let allowsSideEffects: Bool
    private let interface: InterfaceSettings
    private let audio: AudioSettings
    private let recognition: RecognitionSettings
    private let updates: UpdateSettings
    private let llm: LLMSettings
    private let llmRefiner: LLMRefiner
    private weak var reporter: SherpaDownloadReporting?
    private var window: AdaptivePreferencesWindow?
    private var connections: UnifiedConnectionsWindowController?
    private var appearancePane: PreferencesAppearancePane?
    private let notices = AboutWindowController()
    private var promptEditor: PromptEditorController?
    private var page: Page = .general
    private var selectedEngine: String {
        didSet { connections?.updateRecognitionEngineContext(selectedEngine) }
    }
    private var lastCurrentEngine: String
    private var controls: [PreferencesControlAction] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var root: NSStackView!
    private var pageTabs: NSSegmentedControl!
    private var scroll: NSScrollView!
    private var document: NSStackView!
    private var scrollHeight: NSLayoutConstraint!
    private var sizing = false
    private var scheduledResize = false

    init(llmRefiner: LLMRefiner, sherpaDownloadReporter: SherpaDownloadReporting?, allowsSideEffects: Bool = true) {
        self.llmRefiner = llmRefiner
        self.reporter = sherpaDownloadReporter
        self.allowsSideEffects = allowsSideEffects
        let backend: SettingsBackend = allowsSideEffects ? AppSettings.backend : InMemorySettingsBackend()
        self.interface = InterfaceSettings(backend: backend)
        self.audio = AudioSettings(backend: backend)
        self.recognition = RecognitionSettings(backend: backend)
        self.updates = UpdateSettings(backend: backend)
        self.llm = allowsSideEffects ? AppSettings.llm : LLMSettings(backend: backend, apiKeyStore: PreferencesPreviewKeyStore())
        self.selectedEngine = RecognitionSettings(backend: backend).normalizedEngine
        self.lastCurrentEngine = self.selectedEngine
        super.init()
        if allowsSideEffects {
            if let stored = interface.lastPreferencesPage.flatMap(Page.init(rawValue:)) { page = stored }
        }
        let center = NotificationCenter.default
        for name in [AppSettingsEventBus.recognitionEngineNotification, AppSettingsEventBus.llmEnabledNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshVisiblePage() })
        }
    }

    deinit { refreshTimer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func showWindow(page requested: Page? = nil) {
        if window == nil { buildWindow() }
        if let requested { page = requested }
        installPage(animated: window?.isVisible == true)
        if let window { WindowPresenter.shared.bringToFront(window) }
    }

    func showConnections(selecting code: String) {
        selectedEngine = code == "llm" ? recognition.normalizedEngine : code
        showWindow(page: .mode)
        if code == "llm" { connectionController().showRefinement(forRecognitionEngine: selectedEngine) }
        else { connectionController().show(selecting: code) }
    }

    #if DEBUG_BUILD
    func showSnapshot(page identifier: String) {
        let pieces = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        if pieces.first == "connections" { showConnections(selecting: pieces.count > 1 ? pieces[1] : "openai"); return }
        if pieces.first == "models" { showWindow(page: .mode); connectionController().showModels(); return }
        if pieces.first == "hints" { showWindow(page: .mode); connectionController().showHints(); return }
        showWindow(page: Page(rawValue: identifier) ?? .general)
    }
    #endif

    private func buildWindow() {
        let w = AdaptivePreferencesWindow(title: loc("preferences.title"), preferredWidth: Self.preferredContentWidth)
        w.identifier = NSUserInterfaceItemIdentifier("AtomVoice.UnifiedSettingsWindow")
        w.delegate = self
        w.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "AtomVoice.PreferencesToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        w.toolbarStyle = .preference
        w.toolbar = toolbar
        pageTabs = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        pageTabs.segmentStyle = .automatic
        if #available(macOS 27.0, *), pageTabs.responds(to: NSSelectorFromString("setRole:")) {
            // NSSegmentedControlRoleTabs = 1；动态调用公开 setter，兼容没有 role 声明的旧 SDK。
            pageTabs.setValue(1, forKey: "role")
        }
        pageTabs.translatesAutoresizingMaskIntoConstraints = false
        pageTabs.setContentHuggingPriority(.required, for: .vertical)
        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        document = PreferencesFlippedStackView()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 18
        document.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 24, right: 28)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        root = NSStackView(views: [pageTabs, scroll])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        guard let cv = w.contentView else { return }
        cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 300)
        scrollHeight.isActive = true
        window = w
        if allowsSideEffects { AppearancePreference.apply(to: w) }
        else { w.appearance = interface.appearanceMode.appKitAppearance }
        WindowConfiguration.configureKeyViewLoop(w, identifier: "AtomVoice.UnifiedSettingsWindow")
        // 初次展示按屏幕可用区域居中，后续由相对布局保持窗口顶部。
        w.center()
    }

    private func installPage(animated: Bool = true) {
        guard let w = window else { return }
        refreshTimer?.invalidate(); refreshTimer = nil
        controls.removeAll()
        appearancePane = nil
        for child in document.arrangedSubviews { document.removeArrangedSubview(child); child.removeFromSuperview() }
        let leaves: [Page] = page.section == "voice" ? [.input, .mode] : page.section == "system" ? [.permissions, .about] : []
        pageTabs.segmentCount = leaves.count
        for (index, leaf) in leaves.enumerated() { pageTabs.setLabel(leaf.title, forSegment: index); pageTabs.setWidth(0, forSegment: index) }
        pageTabs.selectedSegment = leaves.firstIndex(of: page) ?? 0
        pageTabs.isHidden = leaves.isEmpty
        pageTabs.setAccessibilityLabel(loc("preferences.pages"))
        let content = makePageContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addArrangedSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
        ])
        let parentTitle: String? = page.section == "voice" ? loc("preferences.section.voice") : page.section == "system" ? loc("preferences.section.system") : nil
        w.title = parentTitle.map { "\($0) — \(page.title)" } ?? page.title
        w.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(page.section)
        if allowsSideEffects { interface.lastPreferencesPage = page.rawValue }
        document.layoutSubtreeIfNeeded()
        resizeToContent(animated: animated)
        scroll.contentView.scroll(to: .zero)
        w.recalculateKeyViewLoop()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            content.wantsLayer = true
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; content.animator().alphaValue = 1 }
        }
        if page == .permissions && allowsSideEffects {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissionLabels() }
        }
    }

    private func makePageContent() -> NSView {
        switch page {
        case .general: return makeGeneral()
        case .input: return makeInput()
        case .mode: return makeMode()
        case .appearance:
            let pane = PreferencesAppearancePane(interfaceSettings: interface, appliesApplicationAppearance: allowsSideEffects)
            appearancePane = pane
            return pane.makeView(onSizeChanged: { [weak self] in self?.scheduleResize() }, onChanged: { [weak self] in self?.onSettingsChanged?() })
        case .permissions: return makePermissions()
        case .about: return makeAbout()
        }
    }

    #if DEBUG || DEBUG_BUILD
    /// 离线检查真实控件回调；不创建窗口或读取真实用户配置。
    func makePreviewContent(page: Page) -> NSView {
        precondition(!allowsSideEffects)
        self.page = page
        return makePageContent()
    }
    #endif

    private func scheduleResize() {
        guard !scheduledResize else { return }
        scheduledResize = true
        DispatchQueue.main.async { [weak self] in self?.scheduledResize = false; self?.resizeToContent(animated: true) }
    }

    private func resizeToContent(animated: Bool) {
        guard !sizing, let window, let content = document?.arrangedSubviews.first else { return }
        sizing = true; defer { sizing = false }
        window.contentView?.layoutSubtreeIfNeeded()
        let naturalHeight = ceil(content.fittingSize.height + document.edgeInsets.top + document.edgeInsets.bottom)
        let tabsHeight = pageTabs.isHidden ? 0 : pageTabs.fittingSize.height + root.spacing
        let screen = window.screen ?? NSScreen.main
        let frameInset = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let available = max(80, (screen?.visibleFrame.height ?? naturalHeight + 200) - frameInset - tabsHeight - 36)
        scrollHeight.constant = min(naturalHeight, available)
        let desired = scrollHeight.constant + tabsHeight + 12
        window.resize(contentHeight: desired, animated: animated)
    }

    private func refreshVisiblePage() {
        let current = recognition.normalizedEngine
        if current != lastCurrentEngine { selectedEngine = current; lastCurrentEngine = current }
        guard window?.isVisible == true, window?.attachedSheet == nil else { return }
        if page != .appearance { installPage(animated: false) }
    }

    private func makeGeneral() -> NSView {
        let login = toggle(allowsSideEffects && SMAppService.mainApp.status == .enabled) { [weak self] value in
            guard let self, self.allowsSideEffects else { return }
            do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { self.showError(error.localizedDescription) }
        }
        let language = popup(AppSettings.appLanguageOptions.map { ($0.code, $0.displayName) }, selected: recognition.selectedLanguage) { [weak self] value in
            guard let self else { return }
            self.recognition.selectedLanguage = value
            if self.allowsSideEffects { self.onLanguageChanged?(); self.onSettingsChanged?() }
        }
        return PreferencesLayout.group(rows: [
            PreferencesLayout.row(title: loc("menu.launchAtLogin"), control: login),
            PreferencesLayout.row(title: loc("menu.language"), control: language),
        ])
    }

    private func makeInput() -> NSView {
        let keyboard = KeyboardDiagramView(frame: .zero)
        keyboard.setSelected(interface.triggerKeyCode)
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        let selected = NSTextField(labelWithString: loc("oobe.trigger.selected", loc(TriggerKeyOption.option(for: interface.triggerKeyCode).locKey)))
        selected.alignment = .center
        selected.font = .systemFont(ofSize: 12)
        selected.textColor = .secondaryLabelColor
        keyboard.onSelect = { [weak self, weak selected] code in
            guard let self else { return }
            self.interface.triggerKeyCode = code
            selected?.stringValue = loc("oobe.trigger.selected", loc(TriggerKeyOption.option(for: code).locKey))
            if self.allowsSideEffects { self.onTriggerChanged?(code); self.onSettingsChanged?() }
        }
        let keyboardRow = NSStackView(views: [NSView(), keyboard, NSView()])
        keyboardRow.distribution = .equalCentering
        keyboardRow.orientation = .horizontal
        keyboard.widthAnchor.constraint(equalToConstant: keyboard.intrinsicContentSize.width).isActive = true
        let mode = popup([("hold",loc("menu.inputMode.hold")),("tap",loc("menu.inputMode.tap"))], selected: audio.silenceAutoStopEnabled ? "tap" : "hold") { [weak self] value in
            self?.audio.silenceAutoStopEnabled = value == "tap"; self?.changed(rebuild: true)
        }
        var rows = [PreferencesLayout.row(title: loc("oobe.trigger.mode.title"), control: mode)]
        if audio.silenceAutoStopEnabled {
            var options = [("manual",loc("menu.silence.manualStop"))]
            options += [0.5,1,1.5,2,3,5].map { (String($0), loc("preferences.seconds", $0)) }
            rows.append(PreferencesLayout.row(title: loc("menu.silence.duration"), control: popup(options, selected: audio.tapModeManualStop ? "manual" : String(audio.silenceDuration)) { [weak self] value in
                self?.audio.tapModeManualStop = value == "manual"
                if let seconds = Double(value) { self?.audio.silenceDuration = seconds }
                self?.changed()
            }))
        }
        let headphones = toggle(interface.headphoneControlEnabled) { [weak self] value in
            guard let self else { return }
            if value && self.allowsSideEffects && !HeadphoneControlPrompt.requestEnable() { self.installPage(); return }
            if self.allowsSideEffects { self.onHeadphoneChanged?(value) } else { self.interface.headphoneControlEnabled = value }
            self.changed(rebuild: true)
        }
        rows.append(PreferencesLayout.row(title: loc("menu.headphoneControl"), detail: loc(audio.silenceAutoStopEnabled ? "preferences.headphones.tap" : "preferences.headphones.hold"), control: headphones))
        var devices = [("",loc("menu.audioInput.default"))]
        if allowsSideEffects { devices += AudioEngineController.availableInputDevices().map { ($0.uid,$0.name) } }
        if !devices.contains(where: { $0.0 == audio.audioInputDeviceUID }) { devices.append((audio.audioInputDeviceUID, loc("preferences.unavailableDevice"))) }
        let device = popup(devices, selected: audio.audioInputDeviceUID) { [weak self] value in self?.audio.audioInputDeviceUID = value; self?.changed() }
        let lowerVolume = toggle(audio.lowerVolumeOnRecording) { [weak self] value in self?.audio.lowerVolumeOnRecording = value; self?.changed() }
        return PreferencesLayout.column([
            PreferencesLayout.column([keyboardRow, selected], spacing: 8),
            PreferencesLayout.group(rows: rows),
            PreferencesLayout.group(title: loc("preferences.devices"), rows: [
                PreferencesLayout.row(title: loc("menu.audioInput"), control: device),
                PreferencesLayout.row(title: loc("preferences.lowerVolume"), control: lowerVolume),
                PreferencesLayout.row(title: loc("preferences.soundSettings"), control: button(loc("menu.audioInput.openSystemSettings")) { [weak self] in guard self?.allowsSideEffects == true else { return }; ExternalDestinationOpener.shared.openSoundSettings() }),
            ]),
        ])
    }

    private func makeMode() -> NSView {
        let registry = ASREngineRegistry.shared
        let picker = popup(registry.descriptors.map { ($0.code,loc($0.displayNameKey)) }, selected: selectedEngine) { [weak self] value in self?.selectedEngine = value; self?.installPage() }
        let active = selectedEngine == recognition.normalizedEngine
        var rows = [PreferencesLayout.row(title: loc("menu.recognitionEngine"),
                                          detail: active ? loc("preferences.inUse") : nil, control: picker)]
        let configure = button(loc(selectedEngine == "sherpaOnnx" ? "preferences.manageModels" : "preferences.configure")) { [weak self] in
            guard let self else { return }
            if self.selectedEngine == "sherpaOnnx" { self.connectionController().showModels() } else { self.connectionController().show(selecting: self.selectedEngine) }
        }
        var engineActions: [NSView] = []
        // 只在有真实模型标识时显示模型；不能用供应商名称或离线开关冒充模型。
        if selectedEngine == "openai" || selectedEngine == "sherpaOnnx" {
            let model = selectedEngine == "sherpaOnnx" ? recognition.sherpaModelPresetID
                : (allowsSideEffects ? ((try? AppSettings.openaiASR.configuration())?.resolvedModel.rawValue ?? OpenAIASRModel.live.rawValue) : OpenAIASRModel.live.rawValue)
            rows.append(PreferencesLayout.row(title: loc("settings.model"), detail: model, control: configure))
        } else {
            engineActions.append(configure)
        }
        if !active {
            engineActions.append(button(loc("preferences.useEngine")) { [weak self] in
                guard let self else { return }
                if self.allowsSideEffects { self.onSelectEngine?(self.selectedEngine) } else { self.recognition.engine = self.selectedEngine }
                self.installPage()
            })
        }
        if selectedEngine == "openai", !allowsSideEffects || ((try? AppSettings.openaiASR.configuration())?.resolvedModel.supportsContext == true) {
            rows.append(PreferencesLayout.row(title: loc("preferences.hints.title"), control: button(loc("preferences.edit")) { [weak self] in self?.connectionController().showHints() }))
        }
        if !engineActions.isEmpty { rows.append(PreferencesLayout.trailingActions(engineActions)) }
        var sections = [PreferencesLayout.group(rows: rows)]
        if let provider = RefinementProvider.forRecognitionEngine(selectedEngine) {
            let refinement = toggle(llm.enabled) { [weak self] value in self?.llm.enabled = value; self?.changed(rebuild: true) }
            refinement.setAccessibilityLabel(loc("preferences.refinement"))
            var polishing = [PreferencesLayout.row(title: loc("preferences.refinement"), control: refinement)]
            if llm.enabled {
                let model = provider.matches(baseURL: llm.apiBaseURL) ? llm.model : provider.model
                polishing.append(PreferencesLayout.row(title: loc("settings.model"), detail: model,
                                                       control: button(loc("preferences.configure")) { [weak self] in
                    guard let self else { return }
                    self.connectionController().showRefinement(forRecognitionEngine: self.selectedEngine)
                }))
                polishing.append(PreferencesLayout.row(title: loc("settings.prompt.label"), control: button(loc("settings.prompt.edit")) { [weak self] in self?.editPrompt() }))
            }
            sections.append(PreferencesLayout.group(rows: polishing))
        }
        var output = [PreferencesLayout.row(title: loc("menu.punctuation"), control: toggle(recognition.autoPunctuationEnabled) { [weak self] value in self?.recognition.autoPunctuationEnabled = value; self?.changed() })]
        if registry.isApple(selectedEngine) {
            output.append(PreferencesLayout.row(title: loc("menu.inputMode.liveInsertion"), detail: loc("preferences.appleLive.detail"), control: toggle(audio.appleLiveInsertionEnabled) { [weak self] value in self?.audio.appleLiveInsertionEnabled = value; self?.changed() }))
        }
        sections.append(PreferencesLayout.group(title: loc("preferences.output"), rows: output))
        return PreferencesLayout.column(sections)
    }

    private var permissionLabels: [(PermissionKind,NSTextField)] = []
    private func makePermissions() -> NSView {
        permissionLabels.removeAll()
        let definitions: [(PermissionKind,String,String)] = [(.accessibility,"permission.accessibility.title","preferences.accessibility.detail"),(.microphone,"permission.microphone.title","preferences.microphone.detail"),(.speechRecognition,"permission.speech.title","preferences.speech.detail")]
        let rows = definitions.map { kind,title,detail -> NSView in
            let status = allowsSideEffects ? PermissionService.shared.status(for: kind) : .granted
            let state = label(status.label, color: status.color)
            permissionLabels.append((kind,state))
            let actions = NSStackView(views: [state,button(loc("preferences.systemSettings")) { [weak self] in
                guard let self, self.allowsSideEffects else { return }
                PermissionService.shared.requestOrOpenSettings(for: kind) { [weak self] in self?.refreshPermissionLabels() }
            }]); actions.spacing = 10
            return PreferencesLayout.row(title: loc(title), detail: loc(detail), control: actions)
        }
        return PreferencesLayout.column([
            PreferencesLayout.group(title: loc("preferences.permissions"), rows: rows),
            PreferencesLayout.group(rows: [
                PreferencesLayout.row(title: loc("menu.privacyPolicy"), control: button(loc("preferences.view")) { [weak self] in guard let self, self.allowsSideEffects else { return }; ExternalDestinationOpener.shared.open(PrivacyPolicyURLProvider.currentURL()) }),
                PreferencesLayout.row(title: loc("permissions.troubleshoot"), control: button(loc("preferences.resetPermissions")) { [weak self] in self?.resetPermissions() }),
            ]),
        ])
    }

    private func refreshPermissionLabels() {
        guard page == .permissions, window?.isVisible == true, allowsSideEffects else { return }
        for (kind,label) in permissionLabels { let status = PermissionService.shared.status(for: kind); label.stringValue = status.label; label.textColor = status.color }
    }

    private func makeAbout() -> NSView {
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
        let name = label(loc("app.title")); name.font = .boldSystemFont(ofSize: 24)
        let subtitle = label(loc("preferences.tagline"), color: .secondaryLabelColor)
        let identity = NSStackView(views: [icon,PreferencesLayout.column([name,subtitle], spacing: 6)]); identity.spacing = 18
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        var versionRows = [PreferencesLayout.row(title: loc("preferences.currentVersion"), detail: "\(version) (\(build))", control: button(loc("menu.checkForUpdates")) { [weak self] in guard self?.allowsSideEffects == true else { return }; UpdateChecker.shared.checkForUpdates(silent: false) })]
        versionRows.append(PreferencesLayout.row(title: loc("menu.betaUpdates"), control: toggle(updates.includeBetaUpdates) { [weak self] value in self?.updates.includeBetaUpdates = value; self?.changed() }))
        #if DEBUG_BUILD
        versionRows.append(PreferencesLayout.row(title: loc("menu.debugUpdates"), control: toggle(updates.updateToDebugBuilds) { [weak self] value in self?.updates.updateToDebugBuilds = value; self?.changed() }))
        #endif
        #if DEBUG_BUILD
        if allowsSideEffects, let menu = makeDebugToolsMenu?() {
            let tools = NSPopUpButton(frame: .zero, pullsDown: true)
            menu.insertItem(withTitle: loc("preferences.debug.tools"), action: nil, keyEquivalent: "", at: 0)
            tools.menu = menu
            versionRows.append(PreferencesLayout.row(title: loc("preferences.debug.tools"), control: tools))
        }
        #endif
        return PreferencesLayout.column([
            identity,
            PreferencesLayout.group(rows: versionRows),
            PreferencesLayout.group(title: loc("preferences.support"), rows: [
                PreferencesLayout.row(title: loc("preferences.project"), control: button(loc("preferences.projectLink")) { [weak self] in self?.openURL("https://github.com/BlackSquarre/AtomVoice") }),
                PreferencesLayout.row(title: loc("preferences.developer"), control: button(loc("about.bilibili")) { [weak self] in self?.openURL("https://space.bilibili.com/404899") }),
                PreferencesLayout.row(title: loc("about.thirdParty.link"), control: button(loc("preferences.view")) { [weak self] in guard let self, self.allowsSideEffects else { return }; self.notices.showNotices() }),
            ]),
        ])
    }

    private func connectionController() -> UnifiedConnectionsWindowController {
        if let connections { connections.updateRecognitionEngineContext(selectedEngine); return connections }
        let controller = UnifiedConnectionsWindowController(llmRefiner: llmRefiner, sherpaDownloadReporter: reporter, allowsSideEffects: allowsSideEffects)
        controller.onSaved = { [weak self] in self?.onSettingsChanged?(); self?.refreshVisiblePage() }
        controller.updateRecognitionEngineContext(selectedEngine)
        connections = controller
        return controller
    }

    private func editPrompt() {
        guard allowsSideEffects, let window else { return }
        let editor = PromptEditorController(); promptEditor = editor
        editor.onDone = { [weak self] in self?.onSettingsChanged?() }
        editor.show(in: window) { [weak self] in self?.promptEditor = nil }
    }

    private func changed(rebuild: Bool = false) { if allowsSideEffects { onSettingsChanged?() }; if rebuild { installPage() } }
    private func openURL(_ string: String) { guard allowsSideEffects, let url = URL(string: string) else { return }; ExternalDestinationOpener.shared.open(url) }
    private func resetPermissions() {
        guard allowsSideEffects else { return }
        let alert = NSAlert(); alert.messageText = loc("permissions.reset.confirm.title"); alert.informativeText = loc("permissions.reset.confirm.message")
        alert.addButton(withTitle: loc("permissions.reset.confirm.ok")); alert.addButton(withTitle: loc("common.cancel"))
        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn { PermissionService.shared.resetPermissions(doneMessage: loc("permissions.reset.terminalDone")) }
    }
    private func showError(_ text: String) { let alert = NSAlert(); alert.messageText = text; AlertPresenter.shared.runModalAlert(alert); installPage() }
    private func label(_ title: String, color: NSColor = .labelColor) -> NSTextField { let field = NSTextField(labelWithString: title); field.textColor = color; field.font = .systemFont(ofSize: 13); field.lineBreakMode = .byTruncatingMiddle; return field }
    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let target = PreferencesControlAction { _ in action() }; controls.append(target)
        let button = SettingsUI.makeButton(title, target: target, action: #selector(PreferencesControlAction.invoke(_:)))
        return button
    }
    private func toggle(_ value: Bool, action: @escaping (Bool) -> Void) -> NSSwitch {
        let target = PreferencesControlAction { control in if let control = control as? NSSwitch { action(control.state == .on) } }; controls.append(target)
        let toggle = NSSwitch(); toggle.state = value ? .on : .off; toggle.target = target; toggle.action = #selector(PreferencesControlAction.invoke(_:)); return toggle
    }
    private func popup(_ values: [(String,String)], selected: String, action: @escaping (String) -> Void) -> NSPopUpButton {
        let target = PreferencesControlAction { control in if let value = (control as? NSPopUpButton)?.selectedItem?.representedObject as? String { action(value) } }; controls.append(target)
        let popup = NSPopUpButton(); popup.target = target; popup.action = #selector(PreferencesControlAction.invoke(_:))
        for (value,title) in values { popup.addItem(withTitle: title); popup.lastItem?.representedObject = value }
        if let index = values.firstIndex(where: { $0.0 == selected }) { popup.selectItem(at: index) }
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popup
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let leaves: [Page] = page.section == "voice" ? [.input,.mode] : [.permissions,.about]
        guard leaves.indices.contains(sender.selectedSegment) else { return }
        page = leaves[sender.selectedSegment]; installPage()
    }
    @objc private func toolbarSelected(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier.rawValue { case "voice": page = .input; case "appearance": page = .appearance; case "system": page = .permissions; default: page = .general }
        installPage()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["general","voice","appearance","system"].map { NSToolbarItem.Identifier($0) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "voice": item.label = loc("preferences.section.voice")
        case "appearance": item.label = loc("preferences.section.appearance")
        case "system": item.label = loc("preferences.section.system")
        default: item.label = loc("preferences.section.general")
        }
        let symbols = ["general":"gearshape","voice":"mic","appearance":"rectangle.lefthalf.inset.filled","system":"checkmark.shield"]
        item.image = NSImage(systemSymbolName: symbols[identifier.rawValue] ?? "gearshape", accessibilityDescription: item.label)
        item.target = self; item.action = #selector(toolbarSelected(_:)); return item
    }
    func windowWillClose(_ notification: Notification) { refreshTimer?.invalidate(); refreshTimer = nil; appearancePane = nil; WindowPresenter.shared.resetActivationIfNeeded(closing: window) }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissionLabels() }
    func windowDidChangeScreen(_ notification: Notification) { resizeToContent(animated: false) }
}

private final class PreferencesFlippedStackView: NSStackView { override var isFlipped: Bool { true } }
private final class PreferencesControlAction: NSObject {
    let action: (NSControl) -> Void
    init(_ action: @escaping (NSControl) -> Void) { self.action = action }
    @objc func invoke(_ sender: NSControl) { action(sender) }
}
private final class PreferencesPreviewKeyStore: LLMAPIKeyStoring {
    func read() -> String? { nil }
    func readResult() -> KeychainStringReadResult { .notFound }
    func write(_ value: String) -> Bool { true }
    func delete() -> Bool { true }
}
