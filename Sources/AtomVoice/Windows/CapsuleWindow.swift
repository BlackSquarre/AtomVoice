import Cocoa

private final class CapsuleDragGestureRecognizer: NSGestureRecognizer {
    private let dragThreshold: CGFloat
    private var startScreenPoint: NSPoint?
    private var lastScreenPoint: NSPoint?
    private(set) var delta: CGPoint = .zero

    init(threshold: CGFloat, target: Any?, action: Selector?) {
        self.dragThreshold = threshold
        super.init(target: target, action: action)
    }

    required init?(coder: NSCoder) {
        self.dragThreshold = 4
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = screenPoint(for: event) else {
            state = .failed
            return
        }
        startScreenPoint = point
        lastScreenPoint = point
        delta = .zero
        state = .possible
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startScreenPoint,
              let current = screenPoint(for: event)
        else {
            state = .failed
            return
        }

        switch state {
        case .possible:
            let distance = hypot(current.x - start.x, current.y - start.y)
            guard distance >= dragThreshold else { return }
            delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
            state = .began
        case .began, .changed:
            guard let previous = lastScreenPoint else { return }
            delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            state = .changed
        default:
            return
        }
        lastScreenPoint = current
    }

    override func mouseUp(with event: NSEvent) {
        switch state {
        case .began, .changed:
            state = .ended
        case .possible:
            state = .failed
        default:
            break
        }
    }

    override func reset() {
        startScreenPoint = nil
        lastScreenPoint = nil
        delta = .zero
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window = view?.window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

private final class CapsuleClickOverlayView: NSView, NSGestureRecognizerDelegate {
    var onClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragDelta: ((CGPoint) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let dragGesture = CapsuleDragGestureRecognizer(threshold: 4, target: nil, action: nil)
    private let clickGesture = NSClickGestureRecognizer()
    private let secondaryClickGesture = NSClickGestureRecognizer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureGestureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGestureRecognizers()
    }

    private func configureGestureRecognizers() {
        dragGesture.target = self
        dragGesture.action = #selector(handleDrag(_:))
        dragGesture.delegate = self

        clickGesture.target = self
        clickGesture.action = #selector(handleClick(_:))
        clickGesture.buttonMask = 0x1
        clickGesture.numberOfClicksRequired = 1
        clickGesture.delegate = self

        secondaryClickGesture.target = self
        secondaryClickGesture.action = #selector(handleSecondaryClick(_:))
        secondaryClickGesture.buttonMask = 0x2
        secondaryClickGesture.numberOfClicksRequired = 1

        addGestureRecognizer(dragGesture)
        addGestureRecognizer(clickGesture)
        addGestureRecognizer(secondaryClickGesture)
    }

    @objc private func handleDrag(_ gesture: CapsuleDragGestureRecognizer) {
        switch gesture.state {
        case .began:
            onDragStarted?()
            onDragDelta?(gesture.delta)
        case .changed:
            onDragDelta?(gesture.delta)
        default:
            break
        }
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onClick?()
    }

    @objc private func handleSecondaryClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onSecondaryClick?()
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === clickGesture && otherGestureRecognizer === dragGesture
    }
}

final class CapsuleWindowController {
    enum DisplayMode {
        case normal
        case download
    }

    var onDidDismiss: (() -> Void)?
    var panel: NSPanel?
    var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var refiningLabel: NSTextField?
    var contentView: NSView?
    var animationSurfaceView: NSView?
    private var downloadTrackLayer: CALayer?
    private var downloadFillLayer: CALayer?
    private var downloadProgressValue: Double = 0
    var waveformVisible = true
    var presentationID = 0
    private(set) var isShowingError = false
    private var displayMode: DisplayMode = .normal
    var recordingClickEnabled = false
    var onRecordingClick: (() -> Void)?
    var animationStrategy: any CapsuleAnimationStrategy = CapsuleSpotlightAnimationStrategy(currentInset: CapsuleSpotlightAnimationStrategy.defaultInset)
    let shimmerStrategy: any CapsuleShimmerStrategy = CapsuleDefaultShimmerStrategy()

    #if DEBUG_BUILD
    let elapsedTimerStrategy: any CapsuleElapsedTimerStrategy = CapsuleDebugElapsedTimerStrategy()
    #endif

    let capsuleHeight: CGFloat = 42
    let cornerRadius: CGFloat = 21
    private let waveformWidth: CGFloat = 24
    private let waveformLeadingOffset: CGFloat = 8
    private let waveformTextGap: CGFloat = 12
    private let minTextWidth: CGFloat = 144
    private let maxTextWidth: CGFloat = 504
    private let downloadTextWidth: CGFloat = 320
    private let horizontalPadding: CGFloat = 24
    private let compactMinTextWidth: CGFloat = 56
    private let downloadTrackColor = NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.31, alpha: 0.76)
    private let downloadTrackBorderColor = NSColor(calibratedRed: 0.49, green: 0.72, blue: 1.00, alpha: 0.64)
    private let downloadFillColor = NSColor(calibratedRed: 0.18, green: 0.59, blue: 1.00, alpha: 0.86)
    private let downloadFillHighlightColor = NSColor(calibratedRed: 0.80, green: 0.92, blue: 1.00, alpha: 0.96)
    private let defaultBottomOffset: CGFloat = 54

    var isVisible: Bool { panel != nil }
    var isShowingDownloadPresentation: Bool { panel != nil && displayMode == .download }

    /// 紧凑状态模式：流式上屏时启用，胶囊收窄、只显示固定状态文案，updateText 忽略实时文字
    /// (Compact status mode: enabled during streaming; capsule narrows, shows only a fixed status string,
    ///  updateText ignores live text)
    private var compactStatusKey: String?

    // MARK: - 布局计算

    private func fullWidth(forTextWidth tw: CGFloat, includesWaveform: Bool = true) -> CGFloat {
        // 计时器以半透明叠层呈现，不占据布局宽度（Timer is rendered as a translucent overlay; no extra width.）
        let waveformSpace = includesWaveform ? waveformWidth + waveformLeadingOffset + waveformTextGap : 0
        return tw + waveformSpace + horizontalPadding * 2
    }

    private var savedPlacement: CapsuleWindowPlacement? {
        get { AppSettings.capsuleWindowPlacement }
        set { AppSettings.capsuleWindowPlacement = newValue }
    }

    private func defaultVisualFrame(width: CGFloat, on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let clampedWidth = min(width, visibleFrame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - capsuleHeight)
        let y = min(visibleFrame.minY + defaultBottomOffset, maxY)
        return NSRect(
            x: visibleFrame.midX - clampedWidth / 2,
            y: y,
            width: clampedWidth,
            height: capsuleHeight
        )
    }

    private func targetVisualFrame(width: CGFloat, preferredScreen: NSScreen? = nil) -> NSRect {
        let fallbackScreen = preferredScreen ?? panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = fallbackScreen else {
            return NSRect(x: 0, y: defaultBottomOffset, width: width, height: capsuleHeight)
        }
        guard let placement = savedPlacement else {
            return defaultVisualFrame(width: width, on: screen)
        }
        return visualFrame(width: width, on: resolvedScreen(for: placement) ?? screen, placement: placement)
    }

    private func visualFrame(width: CGFloat, on screen: NSScreen, placement: CapsuleWindowPlacement) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let clampedWidth = min(width, visibleFrame.width)
        let normalizedX = max(0, min(1, placement.centerXRatio))
        let desiredMidX = visibleFrame.minX + visibleFrame.width * normalizedX
        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - clampedWidth)
        let x = min(max(desiredMidX - clampedWidth / 2, minX), maxX)
        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - capsuleHeight)
        let y = min(max(minY + max(0, placement.bottomOffset), minY), maxY)
        return NSRect(x: x, y: y, width: clampedWidth, height: capsuleHeight)
    }

    private func resolvedScreen(for placement: CapsuleWindowPlacement) -> NSScreen? {
        guard let screenID = placement.screenID else { return nil }
        return NSScreen.screens.first { $0.displayID == screenID }
    }

    private func bestMatchingScreen(for visualFrame: NSRect) -> NSScreen? {
        let midpoint = CGPoint(x: visualFrame.midX, y: visualFrame.midY)
        if let containing = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return containing
        }
        return NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(visualFrame).area < rhs.visibleFrame.intersection(visualFrame).area
        }
    }

    private func persistPlacement(for visualFrame: NSRect) {
        guard let screen = bestMatchingScreen(for: visualFrame) else { return }
        let visibleFrame = screen.visibleFrame
        let centerXRatio = (visualFrame.midX - visibleFrame.minX) / visibleFrame.width
        let bottomOffset = visualFrame.minY - visibleFrame.minY
        savedPlacement = CapsuleWindowPlacement(
            screenID: screen.displayID,
            centerXRatio: centerXRatio,
            bottomOffset: bottomOffset
        )
    }

    private func currentVisualFrame(for panel: NSPanel) -> NSRect {
        panel.frame.insetBy(dx: animationStrategy.currentInset, dy: animationStrategy.currentInset)
    }

    func resetUserPlacementToDefault(animated: Bool = true) {
        savedPlacement = nil
        guard let panel else { return }
        let targetScreen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
        let width = currentVisualFrame(for: panel).width
        guard let targetScreen else { return }
        let frame = panelFrame(forVisualFrame: defaultVisualFrame(width: width, on: targetScreen))
        if animated {
            animateFrameChange(panel: panel, frame: frame, currentPresentationID: presentationID)
        } else {
            panel.setFrame(frame, display: false)
            updateShimmerFrame()
        }
    }

    private func beginManualDrag() {
        guard displayMode == .normal else { return }
        animationStrategy.stop()
    }

    private func dragPanel(by delta: CGPoint) {
        guard let panel, displayMode == .normal else { return }
        var frame = panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        panel.setFrame(frame, display: false)
        updateShimmerFrame()
        persistPlacement(for: currentVisualFrame(for: panel))
    }

    func panelFrame(forVisualFrame visualFrame: NSRect) -> NSRect {
        visualFrame.insetBy(dx: -animationStrategy.currentInset, dy: -animationStrategy.currentInset)
    }

    var animationInset: CGFloat {
        animationStrategy.currentInset
    }

    func makeAnimationHost(panel: NSPanel, container: NSView, targetFrame: NSRect) -> CapsuleAnimationHost {
        CapsuleAnimationHost(
            panel: panel,
            container: container,
            animationSurface: animationSurfaceView,
            waveformView: waveformView,
            targetFrame: targetFrame,
            presentationID: presentationID,
            motion: spotlightMotion,
            usesSingleBounceSpotlightAnimation: usesSingleBounceSpotlightAnimation,
            spotlightFrameInterval: spotlightFrameInterval,
            waveformVisible: { [weak self] in self?.waveformVisible == true },
            isCurrent: { [weak self] panel, presentationID in
                self?.panel === panel && self?.presentationID == presentationID
            },
            panelFrame: { [weak self] visualFrame in
                self?.panelFrame(forVisualFrame: visualFrame) ?? visualFrame
            },
            layoutAnimationSurface: { [weak self] panel in
                self?.layoutAnimationSurface(in: panel)
            },
            cleanup: { [weak self] in
                self?.cleanup()
            }
        )
    }

    func makeDismissHost(panel: NSPanel, completion: (() -> Void)?) -> CapsuleDismissHost {
        CapsuleDismissHost(
            panel: panel,
            contentView: contentView,
            animationSurface: animationSurfaceView,
            motion: spotlightMotion,
            usesSingleBounceSpotlightAnimation: usesSingleBounceSpotlightAnimation,
            spotlightFrameInterval: spotlightFrameInterval,
            isCurrent: { [weak self] panel in
                self?.panel === panel
            },
            panelFrame: { [weak self] visualFrame in
                self?.panelFrame(forVisualFrame: visualFrame) ?? visualFrame
            },
            layoutAnimationSurface: { [weak self] panel in
                self?.layoutAnimationSurface(in: panel)
            },
            cleanup: { [weak self] in
                self?.cleanup()
            },
            completion: completion
        )
    }

    func makeShimmerHost() -> ShimmerHost? {
        guard let surface = animationSurfaceView ?? panel?.contentView else { return nil }
        return ShimmerHost(
            animationSurface: surface,
            cornerRadius: cornerRadius,
            capsuleHeight: capsuleHeight
        )
    }

    // MARK: - Show

    /// 确保胶囊面板存在：已存在则复用，不存在才新建。用于错误回弹等"面板可能已被提前收起"的场景。
    /// (Ensure the capsule panel exists: reuse if present, create only if absent — used by error re-presentation.)
    func ensureVisible() {
        if panel == nil { show() }
    }

    func show(showRecordingTimer: Bool = true,
              initialText: String = "",
              showWaveformInitially: Bool = true,
              compactStatusKey: String? = nil,
              displayMode: DisplayMode = .normal) {
        if panel != nil {
            // 上一次 showError 的 3 秒延迟尚未结束时重新录音，先清理旧面板（Previous showError 3s delay hasn't ended when re-recording, clean up old panel first）
            cleanup()
        }
        isShowingError = false
        presentationID += 1
        self.displayMode = displayMode

        waveformVisible = showWaveformInitially

        // 紧凑模式下直接以窄 target 为入场目标，避免入场动画把窄宽度回写为默认宽度
        // (In compact mode, set the entry target to the narrow frame so the spring animation doesn't overwrite it)
        self.compactStatusKey = compactStatusKey
        let labelFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let resolvedInitialText: String
        let resolvedTextWidth: CGFloat
        if displayMode == .download {
            resolvedInitialText = initialText
            resolvedTextWidth = downloadTextWidth
        } else if let key = compactStatusKey {
            let displayText = loc(key)
            resolvedInitialText = displayText
            let measured = (displayText as NSString).size(withAttributes: [.font: labelFont])
            resolvedTextWidth = max(measured.width + 14, compactMinTextWidth)
        } else {
            resolvedInitialText = initialText
            resolvedTextWidth = initialTextWidth(initialText)
        }
        let fw = fullWidth(forTextWidth: resolvedTextWidth, includesWaveform: displayMode != .download)
        let target = targetVisualFrame(width: fw)
        let animationSelection = currentAnimationSelection
        let animationStyle = animationSelection.style
        animationStrategy = CapsuleAnimationStrategyFactory.make(selection: animationSelection)

        let panel = NSPanel(
            contentRect: panelFrame(forVisualFrame: target),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // 使用系统窗口阴影，边缘响应交给 NSGlassEffectView（Use system window shadow, edge response handled by NSGlassEffectView）
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.remove(.titled)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let surface = NSView(frame: panel.contentView!.bounds.insetBy(dx: animationStrategy.currentInset, dy: animationStrategy.currentInset))
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        surface.layer?.masksToBounds = false
        panel.contentView?.addSubview(surface)

        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.alphaValue = (animationStyle == .none && waveformVisible) ? 1 : 0
        container.addSubview(waveform)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = labelFont
        label.textColor = .labelColor
        label.alignment = displayMode == .download ? .center : .natural
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.stringValue = resolvedInitialText
        container.addSubview(label)

        let refLabel = NSTextField(labelWithString: loc("capsule.refining"))
        refLabel.translatesAutoresizingMaskIntoConstraints = false
        refLabel.font = .systemFont(ofSize: 12, weight: .regular)
        refLabel.textColor = .secondaryLabelColor
        refLabel.isHidden = true
        container.addSubview(refLabel)

        let textMinW = label.widthAnchor.constraint(greaterThanOrEqualToConstant: minTextWidth)
        textMinW.priority = .defaultLow
        let textMaxW = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .clear
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.065)
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = container
            // none 模式下禁用 glass view 自带的隐式入场动画（Disable glass view's implicit entry animation in none mode）
            if animationStyle == .none {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setAnimationDuration(0)
            }
            surface.addSubview(glass)
            if animationStyle == .none {
                CATransaction.commit()
            }
            glass.wantsLayer = true
            glass.layer?.masksToBounds = true
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                glass.topAnchor.constraint(equalTo: surface.topAnchor),
                glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: horizontalPadding),
                container.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -horizontalPadding),
                container.topAnchor.constraint(equalTo: glass.topAnchor),
                container.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        } else {
            let fx = NSVisualEffectView(frame: .zero)
            fx.translatesAutoresizingMaskIntoConstraints = false
            fx.material = .popover
            fx.state = .active
            fx.blendingMode = .behindWindow
            fx.wantsLayer = true
            fx.layer?.cornerRadius = cornerRadius
            fx.layer?.masksToBounds = true
            fx.layer?.cornerCurve = .continuous
            fx.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08).cgColor
            fx.layer?.borderWidth = 0.5
            fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            surface.addSubview(fx)
            surface.addSubview(container)
            NSLayoutConstraint.activate([
                fx.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                fx.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                fx.topAnchor.constraint(equalTo: surface.topAnchor),
                fx.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: horizontalPadding),
                container.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -horizontalPadding),
                container.topAnchor.constraint(equalTo: surface.topAnchor),
                container.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            ])
        }

        let clickOverlay = CapsuleClickOverlayView()
        clickOverlay.translatesAutoresizingMaskIntoConstraints = false
        clickOverlay.onClick = { [weak self] in
            guard let self,
                  self.recordingClickEnabled,
                  self.displayMode == .normal,
                  !self.isShowingError
            else { return }
            self.onRecordingClick?()
        }
        clickOverlay.onSecondaryClick = { [weak self] in
            self?.resetUserPlacementToDefault()
        }
        clickOverlay.onDragStarted = { [weak self] in
            self?.beginManualDrag()
        }
        clickOverlay.onDragDelta = { [weak self] delta in
            self?.dragPanel(by: delta)
        }
        surface.addSubview(clickOverlay)
        NSLayoutConstraint.activate([
            clickOverlay.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            clickOverlay.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            clickOverlay.topAnchor.constraint(equalTo: surface.topAnchor),
            clickOverlay.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: waveformLeadingOffset),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformWidth),
            waveform.heightAnchor.constraint(equalToConstant: 29),
            textMinW, textMaxW,
        ])

        if displayMode == .download {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                refLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                refLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                refLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                refLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
                refLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }

        #if DEBUG_BUILD
        if showRecordingTimer {
            startElapsedTimer(in: container)
        }
        #endif

        self.panel = panel
        self.waveformView = waveform
        self.textLabel = label
        self.refiningLabel = refLabel
        self.contentView = container
        self.animationSurfaceView = surface
        if displayMode == .download {
            applyDownloadAppearance(progress: downloadProgressValue)
        }

        animationStrategy.animateIn(host: makeAnimationHost(panel: panel, container: container, targetFrame: target))
    }

    private func initialTextWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return minTextWidth }
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return min(max(measured.width + 18, minTextWidth), maxTextWidth)
    }

    // MARK: - Update

    func updateBands(_ bands: [Float]) {
        waveformView?.updateBands(bands)
    }

    /// 下载等不需要波形的场景调用（Called for scenarios like downloads that don't need waveform）
    func hideWaveform() {
        waveformVisible = false
        waveformView?.stopAnimating()
        waveformView?.alphaValue = 0
    }

    func showWaveform() {
        waveformVisible = true
        waveformView?.alphaValue = 1
        waveformView?.restartAnimating()
    }

    func updateText(_ text: String, completion: (() -> Void)? = nil) {
        // 紧凑状态模式下不展示实时识别文字，避免胶囊跟着文字变长变短
        // (In compact status mode skip live text — keeps capsule width fixed and statusy)
        if compactStatusKey != nil {
            ASRLatencyProbe.finish(text, stage: "capsule_skip_compact")
            completion?()
            return
        }
        updateVisibleText(text, completion: completion)
    }

    private func updateStatusText(_ text: String, completion: (() -> Void)? = nil) {
        updateVisibleText(text, completion: completion)
    }

    private func updateVisibleText(_ text: String, completion: (() -> Void)? = nil) {
        guard let label = textLabel, let panel = panel else {
            ASRLatencyProbe.finish(text, stage: "capsule_missing_ui")
            completion?()
            return
        }
        let currentPresentationID = presentationID
        // 确保文字颜色恢复为默认（showError 会改为红色）（Ensure text color resets to default — showError changes it to red）
        label.textColor = .labelColor
        label.stringValue = text
        label.isHidden = false
        ASRLatencyProbe.finish(text, stage: "capsule_label_set")

        let measured = (text as NSString).size(withAttributes: [.font: label.font!])
        let tw = min(max(measured.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = fullWidth(forTextWidth: tw)

        let targetVisualFrame = self.targetVisualFrame(width: totalWidth, preferredScreen: panel.screen)
        let frame = panelFrame(forVisualFrame: targetVisualFrame)

        animateFrameChange(panel: panel, frame: frame, currentPresentationID: currentPresentationID, completion: completion)
    }

    func showProgress(_ text: String, hidesWaveform: Bool = true) {
        guard panel != nil else {
            show(showRecordingTimer: false, initialText: text, showWaveformInitially: !hidesWaveform)
            refiningLabel?.isHidden = true
            textLabel?.isHidden = false
            let currentPanel = panel
            let currentPresentationID = presentationID
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.panel === currentPanel,
                      self.presentationID == currentPresentationID
                else { return }
                self.applyShimmerToCapsule()
            }
            return
        }
        stopShimmer()
        refiningLabel?.isHidden = true
        textLabel?.isHidden = false
        if hidesWaveform { hideWaveform() }
        // 等 panel 宽度动画结束后再应用扫光，确保 clipLayer 与胶囊实际宽度一致（Wait for panel width animation to finish before applying shimmer, ensuring clipLayer matches actual capsule width）
        // 紧凑模式仍允许进度/错误状态更新；只屏蔽普通实时识别文字，避免弱网时胶囊一直卡在旧状态。
        let update = compactStatusKey == nil ? updateText : updateStatusText
        update(text) { [weak self] in
            self?.applyShimmerToCapsule()
        }
    }

    func showDownloadProgress(_ text: String, progress: Double) {
        downloadProgressValue = min(max(progress, 0), 1)
        guard panel != nil, displayMode == .download else {
            show(showRecordingTimer: false, initialText: text, showWaveformInitially: false, displayMode: .download)
            refiningLabel?.isHidden = true
            textLabel?.isHidden = false
            return
        }

        guard let label = textLabel else { return }
        label.textColor = .labelColor
        label.stringValue = text
        label.isHidden = false
        refiningLabel?.isHidden = true
        hideWaveform()
        updateDownloadProgress(downloadProgressValue)
    }

    private func applyDownloadAppearance(progress: Double) {
        guard let surface = animationSurfaceView else { return }
        surface.wantsLayer = true
        guard let rootLayer = surface.layer else { return }
        stopShimmer()
        downloadTrackLayer?.removeFromSuperlayer()
        downloadTrackLayer = nil
        downloadFillLayer = nil

        let track = CALayer()
        track.frame = surface.bounds
        track.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        track.cornerRadius = cornerRadius
        track.cornerCurve = .continuous
        track.masksToBounds = true
        track.backgroundColor = downloadTrackColor.cgColor
        track.borderWidth = 1
        track.borderColor = downloadTrackBorderColor.cgColor
        track.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.26).cgColor
        track.shadowOpacity = 1
        track.shadowRadius = 10
        track.shadowOffset = CGSize(width: 0, height: -1)

        let fill = CAGradientLayer()
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.position = CGPoint(x: 0, y: surface.bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: 0, height: surface.bounds.height)
        fill.autoresizingMask = [.layerHeightSizable]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.colors = [
            downloadFillColor.cgColor,
            downloadFillHighlightColor.cgColor,
        ]
        fill.locations = [0.0, 1.0]

        track.addSublayer(fill)
        rootLayer.insertSublayer(track, at: 0)
        downloadTrackLayer = track
        downloadFillLayer = fill
        updateDownloadProgress(progress, animated: false)
        applyShimmerToCapsule()
    }

    private func updateDownloadProgress(_ progress: Double, animated: Bool = true) {
        guard let track = downloadTrackLayer, let fill = downloadFillLayer else { return }
        let clamped = min(max(progress, 0), 1)
        let targetBounds = CGRect(x: 0, y: 0, width: track.bounds.width * clamped, height: track.bounds.height)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        fill.position = CGPoint(x: 0, y: track.bounds.midY)
        fill.bounds = targetBounds
        CATransaction.commit()
    }

    func showRecording() {
        displayMode = .normal
        downloadTrackLayer?.removeFromSuperlayer()
        downloadTrackLayer = nil
        downloadFillLayer = nil
        downloadProgressValue = 0
        stopShimmer()
        refiningLabel?.isHidden = true
        // 紧凑模式下保留状态文案"正在输入"
        // (In compact mode keep the status text "Typing" visible)
        textLabel?.isHidden = compactStatusKey == nil
        showWaveform()
    }

    /// 显示错误提示，一段时间后自动消失。（Show error message, auto-dismiss after a delay.）
    func showError(_ message: String, dismissAfter delay: TimeInterval = 3) {
        let currentPanel = panel
        let currentPresentationID = presentationID
        isShowingError = true
        stopShimmer()
        refiningLabel?.isHidden = true
        textLabel?.isHidden = false
        // 错误展示要看清完整文案，强制退出紧凑模式
        // (Errors need full visibility — leave compact mode)
        compactStatusKey = nil
        updateText("⚠️ \(message)")
        // 在 updateText 之后设置红色（updateText 会重置为默认颜色）（Set red color after updateText — updateText resets to default color）
        textLabel?.textColor = .systemRed

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.panel === currentPanel,
                  self.presentationID == currentPresentationID
            else { return }
            self.dismiss()
        }
    }

    func showRefining() {
        textLabel?.isHidden = true
        refiningLabel?.isHidden = false
        waveformView?.stopAnimating()
        if compactStatusKey != nil, let refining = refiningLabel {
            // 紧凑模式下切到优化提示时也按 refining 文案重新计算窄胶囊宽度
            // (Re-fit the narrow capsule width to the refining label in compact mode)
            applyCompactWidth(forText: refining.stringValue, font: refining.font ?? .systemFont(ofSize: 12))
        }
        applyShimmerToCapsule()
    }

    // MARK: - 紧凑状态模式（流式上屏专用）
    // (Compact status mode — for streaming-direct-injection)

    /// 进入紧凑模式：窄胶囊 + 只显示固定状态文案（如"正在输入"）
    /// (Enter compact mode: narrow capsule + fixed status text such as "Typing")
    func enterCompactStatusMode(statusKey: String) {
        compactStatusKey = statusKey
        guard let label = textLabel else { return }
        let displayText = loc(statusKey)
        label.textColor = .labelColor
        label.stringValue = displayText
        label.isHidden = false
        refiningLabel?.isHidden = true
        applyCompactWidth(forText: displayText, font: label.font ?? .systemFont(ofSize: 13.5, weight: .medium))
    }

    /// 切换紧凑模式下的状态文案（typing → refining 等场景）
    /// (Switch the compact mode status text — e.g. typing → refining)
    func updateCompactStatus(statusKey: String) {
        compactStatusKey = statusKey
        guard let label = textLabel else { return }
        let displayText = loc(statusKey)
        label.stringValue = displayText
        label.isHidden = false
        refiningLabel?.isHidden = true
        applyCompactWidth(forText: displayText, font: label.font ?? .systemFont(ofSize: 13.5, weight: .medium))
    }

    func exitCompactStatusMode() {
        compactStatusKey = nil
    }

    private func applyCompactWidth(forText text: String, font: NSFont) {
        guard let panel = panel else { return }
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let tw = max(measured.width + 14, compactMinTextWidth)
        let totalWidth = tw + waveformWidth + waveformLeadingOffset + horizontalPadding * 2 + waveformTextGap

        let targetVisualFrame = self.targetVisualFrame(width: totalWidth, preferredScreen: panel.screen)
        let frame = panelFrame(forVisualFrame: targetVisualFrame)

        animateFrameChange(panel: panel, frame: frame, currentPresentationID: presentationID)
    }

    // MARK: - Dismiss

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); return }
        isShowingError = false
        animationStrategy.stop()
        animationStrategy.dismiss(host: makeDismissHost(panel: panel, completion: completion))
    }

    // MARK: - Debug 计时器

    // MARK: - Cleanup

    func cleanup() {
        let dismissHandler = onDidDismiss
        panel?.orderOut(nil)
        stopShimmer()
        animationStrategy.stop()
        downloadTrackLayer?.removeFromSuperlayer()
        downloadTrackLayer = nil
        downloadFillLayer = nil
        downloadProgressValue = 0
        isShowingError = false
        presentationID += 1
        #if DEBUG_BUILD
        elapsedTimerStrategy.stop()
        #endif
        waveformView?.stopAnimating()
        waveformView = nil
        textLabel = nil
        refiningLabel = nil
        contentView = nil
        animationSurfaceView = nil
        waveformVisible = true
        compactStatusKey = nil
        displayMode = .normal
        panel = nil
        dismissHandler?()
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

private extension NSScreen {
    var displayID: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
