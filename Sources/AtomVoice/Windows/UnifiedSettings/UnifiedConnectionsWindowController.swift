import Cocoa

/// 统一设置的用途编辑器；视图和草稿缓存独立于窗口的显示与关闭。
final class UnifiedConnectionsWindowController: NSObject {
    var onClose: (() -> Void)?
    var onSaved: (() -> Void)?

    private let llmRefiner: LLMRefiner
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    private let allowsSideEffects: Bool
    private var connectionsWindow: AdaptivePreferencesWindow?
    private var modelsWindow: AdaptivePreferencesWindow?
    private var hintsWindow: AdaptivePreferencesWindow?
    private let connectionSurface = ConnectionsContentSurface()
    private let sidebarScrollView = NSScrollView()
    private let sidebarTable = NSTableView()
    private var sidebarRows: [(scope: String?, title: String)] = []
    private var updatingSidebar = false
    private let modelsSurface = ConnectionsContentSurface()
    private let hintsSurface = ConnectionsContentSurface()
    private var currentScope = "apple"
    private var refinementProvider: RefinementProvider?
    private var pages: [String: any ASRSettingsTab] = [:]
    private var pageViews: [String: NSView] = [:]
    private var openAITab: OpenAISettingsTab?
    private var connectionHeading: NSTextField?
    private var statusLabels: [String: NSTextField] = [:]
    private var footerButtons: [String: [NSButton]] = [:]
    private var frameObservers: [String: NSObjectProtocol] = [:]
    private var resizeScheduled = false
    private var resizing = false
    private lazy var llmController = SettingsWindowController(
        llmRefiner: llmRefiner, allowsSideEffects: allowsSideEffects
    )

    init(llmRefiner: LLMRefiner,
         sherpaDownloadReporter: SherpaDownloadReporting?,
         allowsSideEffects: Bool = true) {
        self.llmRefiner = llmRefiner
        self.sherpaDownloadReporter = sherpaDownloadReporter
        self.allowsSideEffects = allowsSideEffects
        super.init()
    }

    deinit {
        frameObservers.values.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show(selecting identifier: String) {
        if identifier == "llm" {
            let engine = allowsSideEffects ? AppSettings.normalizedRecognitionEngine : ASREngineRegistry.appleCode
            showRefinement(forRecognitionEngine: engine)
            return
        }
        if identifier == ASREngineRegistry.sherpaCode || identifier == "sherpa" {
            showModels()
            return
        }
        updateRecognitionEngineContext(identifier)
        showConnections(selecting: identifier)
    }

    /// 供应商由主设置中的识别选择决定；不支持的引擎不打开润色编辑器。
    func showRefinement(forRecognitionEngine code: String) {
        guard let provider = RefinementProvider.forRecognitionEngine(code) else { return }
        refinementProvider = provider
        showConnections(selecting: "llm")
    }

    /// 只更新呈现上下文，不启用引擎、修改润色开关或提交任何连接草稿。
    func updateRecognitionEngineContext(_ code: String) {
        refinementProvider = RefinementProvider.forRecognitionEngine(code)
        guard connectionsWindow != nil else { return }
        if refinementProvider == nil, currentScope == "llm" {
            currentScope = ["apple", "doubao", "openai"].contains(code) ? code : "apple"
            // 只隐藏不再适用的用途；不在切换主选择时建立另一页或读取其密钥。
            connectionsWindow?.orderOut(nil)
            openAITab?.cancelModelListFetch()
            WindowPresenter.shared.resetActivationIfNeeded(closing: connectionsWindow)
        }
        rebuildSidebar()
    }

    private func showConnections(selecting identifier: String) {
        currentScope = ["apple", "openai", "doubao", "llm"].contains(identifier) ? identifier : "apple"
        buildConnectionsWindowIfNeeded()
        installConnectionPage()
        guard let connectionsWindow else { return }
        resizeWindows(animated: false)
        WindowPresenter.shared.bringToFront(connectionsWindow)
        if currentScope == "openai", allowsSideEffects { openAITab?.activateModelList() }
    }

    func showModels() {
        updateRecognitionEngineContext(ASREngineRegistry.sherpaCode)
        if modelsWindow == nil {
            let window = makeWindow(title: loc("preferences.models.title"), width: 700,
                                    identifier: "AtomVoice.PreferencesModelsWindow")
            window.contentView = modelsSurface.makeWindowContent()
            modelsWindow = window
        }
        let page = view(for: "models")
        pages["models"]?.refreshStatus()
        modelsSurface.setViews([page, makeFooter(scope: "models")])
        resizeWindows(animated: false)
        if let modelsWindow { WindowPresenter.shared.bringToFront(modelsWindow) }
    }

    func showHints() {
        _ = view(for: "openai")
        guard let openAITab else { return }
        guard openAITab.supportsContextHints else {
            show(selecting: "openai")
            return
        }
        if hintsWindow == nil {
            let window = makeWindow(title: loc("preferences.hints.title"), width: 620,
                                    identifier: "AtomVoice.PreferencesHintsWindow")
            window.contentView = hintsSurface.makeWindowContent()
            hintsWindow = window
        }
        hintsSurface.setViews([openAITab.makeHintsView(), makeFooter(scope: "hints")])
        resizeWindows(animated: false)
        if let hintsWindow { WindowPresenter.shared.bringToFront(hintsWindow) }
    }

    private func makeWindow(title: String, width: CGFloat, identifier: String) -> AdaptivePreferencesWindow {
        let window = AdaptivePreferencesWindow(title: title, preferredWidth: width)
        window.delegate = self
        if allowsSideEffects {
            AppearancePreference.apply(to: window)
            if !WindowConfiguration.configureRestorableSettingsWindow(window, identifier: identifier) {
                window.center()
            }
        } else {
            WindowConfiguration.configureKeyViewLoop(window, identifier: identifier)
            window.center()
        }
        return window
    }

    private func buildConnectionsWindowIfNeeded() {
        guard connectionsWindow == nil else { return }
        let window = makeWindow(title: loc("preferences.connections.title"), width: 760,
                                identifier: "AtomVoice.PreferencesConnectionsWindow")
        let root = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autohidesScrollers = true
        sidebarTable.headerView = nil
        sidebarTable.style = .sourceList
        sidebarTable.selectionHighlightStyle = .sourceList
        sidebarTable.allowsMultipleSelection = false
        sidebarTable.allowsEmptySelection = false
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebarTable.identifier = NSUserInterfaceItemIdentifier("preferences.connection.sidebar")
        sidebarTable.setAccessibilityLabel(loc("preferences.connections.title"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)
        sidebarTable.delegate = self
        sidebarTable.dataSource = self
        sidebarScrollView.documentView = sidebarTable
        for child in [sidebarScrollView, separator, connectionSurface.scrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        let minimumSidebar = sidebarScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        minimumSidebar.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sidebarScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarScrollView.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.23),
            minimumSidebar,
            separator.leadingAnchor.constraint(equalTo: sidebarScrollView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            connectionSurface.scrollView.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            connectionSurface.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            connectionSurface.scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            connectionSurface.scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        connectionsWindow = window
    }

    private func installConnectionPage() {
        let page = view(for: currentScope)
        if currentScope == "llm" { llmController.refreshEmbeddedStatus() }
        else { pages[currentScope]?.refreshStatus() }
        let heading = NSTextField(labelWithString: title(for: currentScope))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.identifier = NSUserInterfaceItemIdentifier("preferences.connection.heading")
        connectionHeading = heading
        SettingsUI.allowHorizontalWrapping(heading)
        var views = [heading, page]
        if currentScope != "llm" { views.append(makeFooter(scope: currentScope)) }
        connectionSurface.setViews(views)
        rebuildSidebar()
        connectionsWindow?.recalculateKeyViewLoop()
        scheduleResize()
    }

    private func title(for scope: String) -> String {
        switch scope {
        case "llm": return loc(RefinementProvider.openAI.nameKey)
        case "openai": return loc("menu.recognitionEngine.openai")
        case "doubao": return loc("menu.recognitionEngine.doubao")
        default: return loc("menu.recognitionEngine.apple")
        }
    }

    private func rebuildSidebar() {
        updatingSidebar = true
        defer { updatingSidebar = false }
        sidebarRows = [(nil, loc("preferences.connections.recognition"))]
        for scope in ["apple", "doubao", "openai"] { sidebarRows.append((scope, title(for: scope))) }
        // 入口由引擎能力决定；不为构建侧栏提前创建编辑器或读取密钥。
        if let refinementProvider {
            let provider = loc(refinementProvider.nameKey)
            sidebarRows.append((nil, loc("preferences.connections.refinement")))
            sidebarRows.append(("llm", provider))
        }
        sidebarTable.reloadData()
        if let row = sidebarRows.firstIndex(where: { $0.scope == currentScope }) {
            sidebarTable.allowsEmptySelection = false
            sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            sidebarTable.allowsEmptySelection = true
            sidebarTable.deselectAll(nil)
        }
    }

    private func view(for scope: String) -> NSView {
        if let cached = pageViews[scope] {
            if scope == "openai" {
                _ = openAITab?.makeView(includeContext: false, allowsModelFetch: allowsSideEffects)
            }
            return cached
        }
        if scope == "llm" {
            let page = llmController.makeEmbeddedView(
                provider: .openAI,
                parentWindow: { [weak self] in self?.connectionsWindow },
                onSizeChanged: { [weak self] in
                    self?.rebuildSidebar()
                    if self?.currentScope == "llm" { self?.connectionHeading?.stringValue = self?.title(for: "llm") ?? "" }
                    self?.scheduleResize()
                },
                onSaved: { [weak self] in
                    self?.rebuildSidebar()
                    self?.onSaved?()
                }
            )
            pageViews[scope] = page
            observeSize(of: page, scope: scope)
            return page
        }
        let page: any ASRSettingsTab
        if scope == "openai" {
            let openAI: OpenAISettingsTab
            if allowsSideEffects {
                openAI = OpenAISettingsTab(textFieldDelegate: self, usesAsyncCredentials: true)
            } else {
                let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .notFound },
                                                writeKey: { _ in true }, deleteKey: { true })
                openAI = OpenAISettingsTab(textFieldDelegate: self, editor: .init(settings: settings),
                                          allowsExternalActions: false,
                                          loadModels: { _ in [] })
            }
            openAI.onContentSizeChanged = { [weak self] in
                guard let self else { return }
                if self.openAITab?.supportsContextHints == false { self.hintsWindow?.orderOut(nil) }
                self.scheduleResize()
            }
            openAI.onBusyChanged = { [weak self] in self?.updateFooterAvailability() }
            openAI.onOperationCompleted = { [weak self] scope, outcome in self?.finishSave(outcome, scope: scope) }
            openAITab = openAI
            page = openAI
        } else if !allowsSideEffects {
            page = ConnectionsFixturePage(identifier: scope)
        } else if scope == "models" {
            let sherpa = SherpaSettingsTab(
                parentWindow: { [weak self] in self?.modelsWindow },
                onStatusChanged: { [weak self] message, color in
                    self?.setStatus(message, color: color, scope: "models")
                    self?.scheduleResize()
                },
                sherpaDownloadReporter: sherpaDownloadReporter
            )
            sherpa.onContentSizeChanged = { [weak self] in self?.scheduleResize() }
            sherpa.onBusyChanged = { [weak self] in self?.updateFooterAvailability() }
            page = sherpa
        } else if scope == "doubao" {
            let doubao = DoubaoSettingsTab(textFieldDelegate: self, usesAsyncCredentials: true)
            doubao.onBusyChanged = { [weak self] in self?.updateFooterAvailability() }
            doubao.onOperationCompleted = { [weak self] outcome in self?.finishSave(outcome, scope: "doubao") }
            page = doubao
        } else {
            page = AppleSettingsTab()
        }
        pages[scope] = page
        let raw = scope == "openai"
            ? openAITab!.makeView(includeContext: false, allowsModelFetch: allowsSideEffects)
            : page.makeView()
        let content = unwrapScrollablePage(raw)
        // Apple 旧页面未钉住末行；补自然高度约束，避免把其内容当成零高。
        if scope == "apple", allowsSideEffects, let last = content.subviews.last {
            last.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16).isActive = true
        }
        page.refresh()
        pageViews[scope] = content
        observeSize(of: content, scope: scope)
        return content
    }

    private func unwrapScrollablePage(_ raw: NSView) -> NSView {
        guard let scroll = raw as? NSScrollView, let document = scroll.documentView else { return raw }
        let constraints = scroll.contentView.constraints.filter {
            ($0.firstItem as? NSView) === document || ($0.secondItem as? NSView) === document
        }
        NSLayoutConstraint.deactivate(constraints)
        scroll.documentView = nil
        document.translatesAutoresizingMaskIntoConstraints = false
        return document
    }

    private func makeFooter(scope: String) -> NSView {
        let status = SettingsUI.makeSecondaryLabel()
        status.identifier = NSUserInterfaceItemIdentifier("preferences.status." + scope)
        SettingsUI.allowHorizontalWrapping(status)
        statusLabels[scope] = status
        let discard = SettingsUI.makeButton(loc("preferences.discard"), target: self, action: #selector(discardScope(_:)))
        discard.identifier = NSUserInterfaceItemIdentifier(scope)
        let save = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveScope(_:)))
        save.identifier = NSUserInterfaceItemIdentifier(scope)
        save.keyEquivalent = "\r"
        footerButtons[scope] = [discard, save]
        updateFooterAvailability()
        return SettingsUI.makeBottomRow(statusLabel: status, buttons: [discard, save])
    }

    private func page(forScope scope: String) -> (any ASRSettingsTab)? {
        pages[scope == "hints" ? "openai" : scope]
    }

    @objc private func saveScope(_ sender: NSButton) {
        guard let scope = sender.identifier?.rawValue, let page = page(forScope: scope) else { return }
        let outcome = scope == "hints" ? (openAITab?.saveHints() ?? .saved) : page.save()
        finishSave(outcome, scope: scope)
    }

    private func finishSave(_ outcome: ASRSettingsTabSaveOutcome, scope: String) {
        switch outcome {
        case .saved:
            setStatus(loc("settings.saved"), color: .systemGreen, scope: scope)
            onSaved?()
        case .deferred:
            setStatus(loc(scope == "models" ? "asrSettings.sherpa.downloading" : "settings.saving"), color: .systemBlue, scope: scope)
        case let .failed(message, color):
            setStatus(message, color: color, scope: scope)
        }
        scheduleResize()
    }

    private func isScopeBusy(_ scope: String) -> Bool {
        if scope == "openai" || scope == "hints" { return openAITab?.isBusy == true }
        if scope == "models" { return (pages[scope] as? SherpaSettingsTab)?.isBusy == true }
        return (pages[scope] as? DoubaoSettingsTab)?.isBusy == true
    }

    private func updateFooterAvailability() {
        for (scope, controls) in footerButtons {
            controls.forEach { $0.isEnabled = !isScopeBusy(scope) }
        }
    }

    @objc private func discardScope(_ sender: NSButton) {
        guard let scope = sender.identifier?.rawValue, !isScopeBusy(scope) else { return }
        if scope == "hints" {
            openAITab?.discardHints()
            setStatus("", color: .secondaryLabelColor, scope: "hints")
        } else if scope == "openai" {
            openAITab?.discardConnectionChanges()
            setStatus("", color: .secondaryLabelColor, scope: "openai")
        } else {
            // 旧 Apple/Sherpa 的 refresh 只刷新状态，重新建立当前页才真正丢弃其草稿。
            pages.removeValue(forKey: scope)
            pageViews.removeValue(forKey: scope)
            if scope == "models" { showModels() }
            else { installConnectionPage() }
        }
        scheduleResize()
    }

    private func setStatus(_ message: String, color: NSColor, scope: String) {
        statusLabels[scope]?.stringValue = message
        statusLabels[scope]?.textColor = color
    }

    private func observeSize(of view: NSView, scope: String) {
        if let previous = frameObservers.removeValue(forKey: scope) {
            NotificationCenter.default.removeObserver(previous)
        }
        view.postsFrameChangedNotifications = true
        frameObservers[scope] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in self?.scheduleResize() }
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeWindows(animated: true)
        }
    }

    private func resizeWindows(animated: Bool) {
        guard !resizing else { return }
        resizing = true
        defer { resizing = false }
        for window in [connectionsWindow, modelsWindow, hintsWindow].compactMap({ $0 }) {
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if let window = connectionsWindow {
            resize(window, surface: connectionSurface,
                   naturalHeight: max(connectionSurface.requiredHeight, CGFloat(sidebarRows.count) * 29 + 24),
                   animated: animated)
        }
        if let window = modelsWindow {
            resize(window, surface: modelsSurface, naturalHeight: modelsSurface.requiredHeight, animated: animated)
        }
        if let window = hintsWindow {
            resize(window, surface: hintsSurface, naturalHeight: hintsSurface.requiredHeight, animated: animated)
        }
    }

    private func resize(_ window: AdaptivePreferencesWindow, surface: ConnectionsContentSurface,
                        naturalHeight: CGFloat, animated: Bool) {
        let frameInset = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? naturalHeight + frameInset
        let viewportHeight = min(naturalHeight, max(1, visibleHeight - frameInset - 24))
        // 只约束视口，不把长表单压进屏幕；文档保留自然高度供滚动。
        surface.setViewportHeight(viewportHeight)
        window.contentView?.layoutSubtreeIfNeeded()
        window.resize(contentHeight: viewportHeight, animated: animated)
    }

    #if DEBUG_BUILD
    /// 供离线布局检查创建内容，不展示窗口，也不访问真实设置或模型资源。
    func makeFixtureContent(selecting scope: String) -> NSView {
        precondition(!allowsSideEffects)
        if scope == "hints" {
            _ = view(for: "openai")
            return openAITab!.makeHintsView()
        }
        return view(for: scope)
    }
    #endif
}

extension UnifiedConnectionsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        sidebarRows[row].scope == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        sidebarRows[row].scope != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        sidebarRows[row].scope == nil ? 24 : 27
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sidebarRows[row]
        let grouped = item.scope == nil
        let identifier = NSUserInterfaceItemIdentifier(grouped ? "connectionGroupCell" : "connectionItemCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let label: NSTextField
        if let existing = cell.textField { label = existing }
        else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        label.stringValue = item.title
        label.font = .systemFont(ofSize: grouped ? 11 : 13, weight: grouped ? .semibold : .regular)
        label.textColor = grouped ? .secondaryLabelColor : .labelColor
        cell.toolTip = item.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSidebar, (notification.object as? NSTableView) === sidebarTable,
              sidebarRows.indices.contains(sidebarTable.selectedRow),
              let scope = sidebarRows[sidebarTable.selectedRow].scope, scope != currentScope else { return }
        if scope != "openai" { openAITab?.cancelModelListFetch() }
        currentScope = scope
        installConnectionPage()
        if scope == "openai", allowsSideEffects { openAITab?.activateModelList() }
    }
}

extension UnifiedConnectionsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === connectionsWindow { openAITab?.cancelModelListFetch() }
        WindowPresenter.shared.resetActivationIfNeeded(closing: closing)
        let anotherVisible = [connectionsWindow, modelsWindow, hintsWindow].compactMap { $0 }
            .contains { $0 !== closing && $0.isVisible }
        if !anotherVisible { onClose?() }
    }
}

extension UnifiedConnectionsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField)?.identifier?.rawValue == "openai.apiKey" {
            openAITab?.apiKeyDidChange()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        control.window?.selectNextKeyView(nil)
        return true
    }
}

private final class ConnectionsDocumentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 长表单只保留宿主这一层滚动，窗口按内容自然高度伸缩。
private final class ConnectionsContentSurface {
    let scrollView = NSScrollView()
    private let document = ConnectionsDocumentStackView()
    private let padding: CGFloat
    private var viewportHeight: NSLayoutConstraint?

    init(padding: CGFloat = 24) {
        self.padding = padding
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        document.orientation = .vertical
        document.alignment = .leading
        document.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    func setViews(_ views: [NSView], spacing: CGFloat = 16) {
        for child in document.arrangedSubviews {
            document.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        document.spacing = spacing
        for child in views {
            child.translatesAutoresizingMaskIntoConstraints = false
            document.addArrangedSubview(child)
            child.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: padding).isActive = true
            child.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -padding).isActive = true
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var requiredHeight: CGFloat {
        document.layoutSubtreeIfNeeded()
        let children = document.arrangedSubviews.filter { !$0.isHidden }
        let heights = children.reduce(CGFloat.zero) { $0 + $1.fittingSize.height }
        return max(1, ceil(heights + CGFloat(max(0, children.count - 1)) * document.spacing + padding * 2))
    }

    func setViewportHeight(_ height: CGFloat) {
        if let viewportHeight { viewportHeight.constant = height }
        else {
            let constraint = scrollView.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            viewportHeight = constraint
        }
    }

    func makeWindowContent() -> NSView {
        let root = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }
}

/// 无副作用预览不复用会查询系统语音能力或磁盘资源的页面。
private final class ConnectionsFixturePage: ASRSettingsTab {
    let identifier: String
    var label: String { identifier }
    var hasChanges: Bool { false }
    init(identifier: String) { self.identifier = identifier }
    func refresh() {}
    func save() -> ASRSettingsTabSaveOutcome { .saved }

    func makeView() -> NSView {
        if identifier == "apple" {
            let offline = SettingsUI.makeCheckbox(title: loc("asrSettings.apple.enable"), tooltip: "")
            return PreferencesLayout.group(rows: [
                PreferencesLayout.row(title: loc("asrSettings.apple.status"),
                                      control: NSTextField(labelWithString: loc("asrSettings.apple.modelDownloaded"))),
                offline,
            ])
        }
        if identifier == "models" {
            let language = NSPopUpButton()
            language.addItems(withTitles: [AppSettings.displayName(forRecognitionLanguage: "zh-CN"),
                                          AppSettings.displayName(forRecognitionLanguage: "en-US")])
            let models = ["zh-14M (52 MB)", "zh-multi (296 MB)"].enumerated().map { index, title -> NSView in
                let choice = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
                choice.state = index == 1 ? .on : .off
                let row = NSStackView(views: [choice])
                row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
                return row
            }
            let download = NSButton(title: loc("asrSettings.sherpa.download"), target: nil, action: nil)
            download.bezelStyle = .rounded
            download.isEnabled = false
            return PreferencesLayout.column([
                PreferencesLayout.row(title: loc("asrSettings.sherpa.recognitionLanguage"), control: language),
                PreferencesLayout.group(title: loc("asrSettings.tab.sherpa"), rows: models), download,
            ])
        }
        let service = NSPopUpButton()
        service.addItems(withTitles: DoubaoService.allCases.map(\.title))
        let model = NSPopUpButton()
        model.addItems(withTitles: [loc("doubao.model.v2"), loc("doubao.model.v1")])
        return PreferencesLayout.group(rows: [
            PreferencesLayout.row(title: loc("doubao.settings.service"), control: service),
            PreferencesLayout.row(title: loc("doubao.settings.apiKey"),
                                  control: NSSecureTextField(string: "")),
            PreferencesLayout.row(title: loc("doubao.settings.resourceID"), control: model),
        ])
    }
}
