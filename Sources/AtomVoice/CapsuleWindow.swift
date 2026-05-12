import Cocoa

final class CapsuleWindowController {
    enum DisplayMode {
        case normal
        case download
    }

    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var refiningLabel: NSTextField?
    private var contentView: NSView?
    private var animationSurfaceView: NSView?
    private var downloadTintLayer: CALayer?
    private var springTimer: Timer?
    private var shimmerLayer: CAGradientLayer?
    private var shimmerClipLayer: CALayer?  // 裁剪为胶囊形状的容器层（Clipping container layer shaped as capsule）
    private var activeAnimationInset: CGFloat = 0
    private var waveformVisible = true
    private var presentationID = 0
    private(set) var isShowingError = false
    private var displayMode: DisplayMode = .normal

    #if DEBUG_BUILD
    private var timerLabel: NSTextField?
    private var elapsedTimer: Timer?
    private var recordingStartTime: Date?
    private let timerLabelWidth: CGFloat = 34
    #endif

    private let capsuleHeight: CGFloat = 42
    private let cornerRadius: CGFloat = 21
    private let waveformWidth: CGFloat = 24
    private let waveformLeadingOffset: CGFloat = 8
    private let waveformTextGap: CGFloat = 12
    private let minTextWidth: CGFloat = 144
    private let maxTextWidth: CGFloat = 504
    private let downloadTextWidth: CGFloat = 320
    private let horizontalPadding: CGFloat = 24
    private let compactMinTextWidth: CGFloat = 56

    /// 紧凑状态模式：流式上屏时启用，胶囊收窄、只显示固定状态文案，updateText 忽略实时文字
    /// (Compact status mode: enabled during streaming; capsule narrows, shows only a fixed status string,
    ///  updateText ignores live text)
    private var compactStatusKey: String?
    private let spotlightAnimationInset: CGFloat = 18
    private let spotlightInBlurRadius: CGFloat = 14
    private let spotlightOutBlurRadius: CGFloat = 10

    // Spotlight 式弹性动效参数，根据菜单速度动态读取（Spotlight-style spring animation parameters, dynamically read from menu speed）
    private var spotlightMotion: (inScale: CGFloat, overshootScale: CGFloat, settleScale: CGFloat, outScale: CGFloat, fadeIn: TimeInterval, fadeOut: TimeInterval, blurIn: TimeInterval, scaleIn: TimeInterval, scaleOut: TimeInterval) {
        switch UserDefaults.standard.string(forKey: "animationSpeed") ?? "medium" {
        case "slow": return (0.72, 1.045, 0.985, 0.92, 0.08, 0.14, 0.18, 0.34, 0.14)
        case "fast": return (0.82, 1.025, 0.995, 0.94, 0.04, 0.09, 0.09, 0.20, 0.09)
        default:     return (0.78, 1.035, 0.99, 0.93, 0.055, 0.11, 0.12, 0.26, 0.11)
        }
    }

    private var animationStyle: String {
        UserDefaults.standard.string(forKey: "animationStyle") ?? "dynamicIsland"
    }

    private var usesSingleBounceSpotlightAnimation: Bool {
        (NSScreen.main?.maximumFramesPerSecond ?? 60) <= 60
    }

    private var spotlightFrameInterval: TimeInterval {
        usesSingleBounceSpotlightAnimation ? 1.0 / 60.0 : 1.0 / 120.0
    }

    // MARK: - 布局计算

    private func fullWidth(forTextWidth tw: CGFloat) -> CGFloat {
        // 计时器以半透明叠层呈现，不占据布局宽度（Timer is rendered as a translucent overlay; no extra width.）
        return tw + waveformWidth + waveformLeadingOffset + horizontalPadding * 2 + waveformTextGap
    }

    private func targetFrame(width: CGFloat) -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? .zero
        return NSRect(x: s.midX - width / 2, y: s.minY + 54, width: width, height: capsuleHeight)
    }

    private func panelFrame(forVisualFrame visualFrame: NSRect) -> NSRect {
        visualFrame.insetBy(dx: -activeAnimationInset, dy: -activeAnimationInset)
    }

    // MARK: - Show

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
        let fw = fullWidth(forTextWidth: resolvedTextWidth)
        let target = targetFrame(width: fw)
        activeAnimationInset = animationStyle == "dynamicIsland" ? spotlightAnimationInset : 0

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

        let surface = NSView(frame: panel.contentView!.bounds.insetBy(dx: activeAnimationInset, dy: activeAnimationInset))
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        surface.layer?.masksToBounds = false
        panel.contentView?.addSubview(surface)

        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.alphaValue = (animationStyle == "none" && waveformVisible) ? 1 : 0
        container.addSubview(waveform)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = labelFont
        label.textColor = .labelColor
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
            if animationStyle == "none" {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setAnimationDuration(0)
            }
            surface.addSubview(glass)
            if animationStyle == "none" {
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

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: waveformLeadingOffset),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformWidth),
            waveform.heightAnchor.constraint(equalToConstant: 29),
            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textMinW, textMaxW,
            refLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
            refLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        label.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true

        #if DEBUG_BUILD
        if showRecordingTimer {
            // 计时器标签：作为底层半透明叠层显示在右侧，不占据布局宽度
            // (Timer label: shown as a translucent underlay on the right; takes no layout width.)
            let timerLbl = NSTextField(labelWithString: "0s")
            timerLbl.translatesAutoresizingMaskIntoConstraints = false
            timerLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            timerLbl.textColor = .tertiaryLabelColor
            timerLbl.alphaValue = 0.55
            timerLbl.alignment = .right
            // 放在所有子视图最底层，文字变长时会盖住计时器（Place beneath all siblings so long recognized text covers it.）
            container.addSubview(timerLbl, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                timerLbl.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                timerLbl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                timerLbl.widthAnchor.constraint(equalToConstant: timerLabelWidth),
            ])
            self.timerLabel = timerLbl
            startElapsedTimer()
        }
        #endif

        self.panel = panel
        self.waveformView = waveform
        self.textLabel = label
        self.refiningLabel = refLabel
        self.contentView = container
        self.animationSurfaceView = surface
        if displayMode == .download {
            applyDownloadAppearance()
        }

        switch animationStyle {
        case "none":    animateInNone(panel: panel, targetFrame: target)
        case "minimal": animateInMinimal(panel: panel, targetFrame: target)
        default:        animateInSpring(panel: panel, container: container, targetFrame: target)
        }
    }

    private func initialTextWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return minTextWidth }
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return min(max(measured.width + 18, minTextWidth), maxTextWidth)
    }

    // MARK: - Spotlight 入场：中心弹性缩放 + 高斯模糊收敛

    private func setCenterAnchor(for layer: CALayer) {
        let savedBounds = layer.bounds
        let savedPosition = layer.position
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = savedBounds
        layer.position = savedPosition
    }

    private func visualFrame(_ frame: NSRect, scaledBy scale: CGFloat) -> NSRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private func visualFrame(_ frame: NSRect, widthScale: CGFloat, heightScale: CGFloat) -> NSRect {
        let width = frame.width * widthScale
        let height = frame.height * heightScale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    private func easeInCubic(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * t
    }

    private func spotlightInScale(progress: CGFloat, motion: (inScale: CGFloat, overshootScale: CGFloat, settleScale: CGFloat, outScale: CGFloat, fadeIn: TimeInterval, fadeOut: TimeInterval, blurIn: TimeInterval, scaleIn: TimeInterval, scaleOut: TimeInterval)) -> CGFloat {
        if progress < 0.52 {
            let t = easeOutCubic(progress / 0.52)
            return motion.inScale + (motion.overshootScale - motion.inScale) * t
        }
        if progress < 0.78 {
            let t = easeOutCubic((progress - 0.52) / 0.26)
            return motion.overshootScale + (motion.settleScale - motion.overshootScale) * t
        }
        let t = easeOutCubic((progress - 0.78) / 0.22)
        return motion.settleScale + (1.0 - motion.settleScale) * t
    }

    private func spotlightInScales(progress: CGFloat) -> (width: CGFloat, height: CGFloat) {
        if usesSingleBounceSpotlightAnimation {
            if progress < 0.58 {
                let t = easeOutCubic(progress / 0.58)
                return (
                    width: 1.10 + (0.985 - 1.10) * t,
                    height: 0.76 + (1.05 - 0.76) * t
                )
            }
            let t = easeOutCubic((progress - 0.58) / 0.42)
            return (
                width: 0.985 + (1.0 - 0.985) * t,
                height: 1.05 + (1.0 - 1.05) * t
            )
        }

        if progress < 0.48 {
            let t = easeOutCubic(progress / 0.48)
            return (
                width: 1.16 + (0.965 - 1.16) * t,
                height: 0.68 + (1.08 - 0.68) * t
            )
        }
        if progress < 0.76 {
            let t = easeOutCubic((progress - 0.48) / 0.28)
            return (
                width: 0.965 + (1.012 - 0.965) * t,
                height: 1.08 + (0.985 - 1.08) * t
            )
        }
        let t = easeOutCubic((progress - 0.76) / 0.24)
        return (
            width: 1.012 + (1.0 - 1.012) * t,
            height: 0.985 + (1.0 - 0.985) * t
        )
    }

    private func spotlightOutScale(progress: CGFloat, motion: (inScale: CGFloat, overshootScale: CGFloat, settleScale: CGFloat, outScale: CGFloat, fadeIn: TimeInterval, fadeOut: TimeInterval, blurIn: TimeInterval, scaleIn: TimeInterval, scaleOut: TimeInterval)) -> CGFloat {
        if usesSingleBounceSpotlightAnimation {
            let t = easeInCubic(progress)
            return 1.0 + (motion.outScale - 1.0) * t
        }

        if progress < 0.28 {
            let t = easeOutCubic(progress / 0.28)
            return 1.0 + (1.012 - 1.0) * t
        }
        let t = easeInCubic((progress - 0.28) / 0.72)
        return 1.012 + (motion.outScale - 1.012) * t
    }

    private func layoutAnimationSurface(in panel: NSPanel) {
        guard let surface = animationSurfaceView, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let frame = host.bounds.insetBy(dx: activeAnimationInset, dy: activeAnimationInset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = frame
        if let layer = surface.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.bounds = CGRect(origin: .zero, size: frame.size)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        CATransaction.commit()

        surface.layoutSubtreeIfNeeded()
        updateShimmerFrame()
    }

    private func animateInSpring(panel: NSPanel, container: NSView, targetFrame: NSRect) {
        let motion = spotlightMotion
        let initialScales = spotlightInScales(progress: 0)
        panel.setFrame(panelFrame(forVisualFrame: visualFrame(targetFrame, widthScale: initialScales.width, heightScale: initialScales.height)), display: false)
        panel.alphaValue = 0
        container.alphaValue = 0

        panel.contentView?.wantsLayer = true
        let surface = animationSurfaceView ?? panel.contentView
        surface?.wantsLayer = true
        surface?.layer?.masksToBounds = false
        surface?.layer?.transform = CATransform3DIdentity
        container.wantsLayer = true
        layoutAnimationSurface(in: panel)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(spotlightInBlurRadius, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false
        }

        panel.orderFrontRegardless()
        panel.invalidateShadow()

        // 延迟一帧，让 glass/effect view 先采样背景，避免首帧白色 fallback（Delay one frame for glass/effect view to sample background, avoid white fallback on first frame）
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            if self.waveformVisible {
                self.waveformView?.restartAnimating()
            } else {
                self.waveformView?.stopAnimating()
                self.waveformView?.alphaValue = 0
            }

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = self.spotlightInBlurRadius
            blurAnim.toValue = 0.0
            blurAnim.duration = motion.blurIn
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurIn")

            self.springTimer?.invalidate()
            let startedAt = CACurrentMediaTime()
            let duration = self.usesSingleBounceSpotlightAnimation ? min(motion.scaleIn, 0.22) : motion.scaleIn
            let dt = self.spotlightFrameInterval
            self.springTimer = Timer(timeInterval: dt, repeats: true) { [weak self, weak panel] timer in
                guard let self, let panel, self.panel === panel else {
                    timer.invalidate()
                    return
                }

                let elapsed = CACurrentMediaTime() - startedAt
                let progress = min(1, CGFloat(elapsed / duration))
                let scales = self.spotlightInScales(progress: progress)
                panel.setFrame(self.panelFrame(forVisualFrame: self.visualFrame(targetFrame, widthScale: scales.width, heightScale: scales.height)), display: false)
                self.layoutAnimationSurface(in: panel)

                panel.alphaValue = min(1, CGFloat(elapsed / motion.fadeIn))
                let contentDelay: TimeInterval = 0.025
                let contentFade = max(0, CGFloat((elapsed - contentDelay) / max(0.001, motion.fadeIn)))
                container.alphaValue = min(1, contentFade)
                self.waveformView?.alphaValue = self.waveformVisible ? container.alphaValue : 0

                if progress >= 1 {
                    timer.invalidate()
                    self.springTimer = nil
                    panel.setFrame(self.panelFrame(forVisualFrame: targetFrame), display: false)
                    self.layoutAnimationSurface(in: panel)
                    panel.alphaValue = 1
                    container.alphaValue = 1
                    self.waveformView?.alphaValue = self.waveformVisible ? 1 : 0
                    container.layer?.filters = nil
                    container.layer?.removeAnimation(forKey: "spotlightBlurIn")
                    panel.invalidateShadow()
                }
            }
            RunLoop.main.add(self.springTimer!, forMode: .common)
        }
    }

    // MARK: - 无动画入场

    private func animateInNone(panel: NSPanel, targetFrame: NSRect) {
        // 清空任何残留 filter（Clear any residual filters）
        contentView?.layer?.filters = nil
        contentView?.layer?.removeAllAnimations()
        contentView?.alphaValue = 1
        waveformView?.alphaValue = waveformVisible ? 1 : 0
        if waveformVisible {
            waveformView?.restartAnimating()
        } else {
            waveformView?.stopAnimating()
        }

        panel.setFrame(panelFrame(forVisualFrame: targetFrame), display: false)
        layoutAnimationSurface(in: panel)
        panel.alphaValue = 1

        // 三重禁用：CATransaction + NSAnimationContext + animator duration（Triple disable: CATransaction + NSAnimationContext + animator duration）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.orderFrontRegardless()
        // 强制立即渲染，不等下一 runloop（Force immediate render, don't wait for next runloop）
        panel.display()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    // MARK: - 无动画退场

    private func dismissNone(panel: NSPanel, completion: (() -> Void)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.orderOut(nil)
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        cleanup()
        completion?()
    }

    // MARK: - 简约模式入场

    private func animateInMinimal(panel: NSPanel, targetFrame: NSRect) {
        let currentPresentationID = presentationID
        panel.contentView?.wantsLayer = true
        animationSurfaceView?.wantsLayer = true
        panel.alphaValue = 0
        contentView?.alphaValue = 0
        var start = panelFrame(forVisualFrame: targetFrame); start.origin.y -= 8
        panel.setFrame(start, display: false)
        layoutAnimationSurface(in: panel)
        animationSurfaceView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        panel.orderFrontRegardless()

        // 延迟一帧，让 visual effect view 先采样背景（Delay one frame for visual effect view to sample background）
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.panel === panel,
                  self.presentationID == currentPresentationID
            else { return }
            if self.waveformVisible {
                self.waveformView?.restartAnimating()
            } else {
                self.waveformView?.stopAnimating()
                self.waveformView?.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                self.contentView?.animator().alphaValue = 1
                self.waveformView?.animator().alphaValue = self.waveformVisible ? 1 : 0
                panel.animator().setFrame(self.panelFrame(forVisualFrame: targetFrame), display: true)
                self.animationSurfaceView?.layer?.transform = CATransform3DIdentity
            })
        } // end DispatchQueue.main.async
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
        if compactStatusKey != nil { completion?(); return }
        guard let label = textLabel, let panel = panel else { completion?(); return }
        let currentPresentationID = presentationID
        // 确保文字颜色恢复为默认（showError 会改为红色）（Ensure text color resets to default — showError changes it to red）
        label.textColor = .labelColor
        label.stringValue = text
        label.isHidden = false

        let measured = (text as NSString).size(withAttributes: [.font: label.font!])
        let tw = min(max(measured.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = fullWidth(forTextWidth: tw)

        let screen = NSScreen.main?.visibleFrame ?? .zero
        var visualFrame = panel.frame.insetBy(dx: activeAnimationInset, dy: activeAnimationInset)
        visualFrame.size.width = totalWidth
        visualFrame.origin.x = screen.midX - totalWidth / 2
        let frame = panelFrame(forVisualFrame: visualFrame)

        if animationStyle == "none" {
            panel.setFrame(frame, display: false)
            updateShimmerFrame()
            completion?()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animationStyle == "dynamicIsland" ? 0.16 : 0.2
                ctx.timingFunction = animationStyle == "dynamicIsland"
                    ? CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                    : CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                guard let self,
                      self.panel === panel,
                      self.presentationID == currentPresentationID
                else { return }
                self.updateShimmerFrame()
                completion?()
            })
        }
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
        updateText(text) { [weak self] in
            self?.applyShimmerToCapsule()
        }
    }

    func showDownloadProgress(_ text: String) {
        guard panel != nil, displayMode == .download else {
            show(showRecordingTimer: false, initialText: text, showWaveformInitially: false, displayMode: .download)
            refiningLabel?.isHidden = true
            textLabel?.isHidden = false
            DispatchQueue.main.async { [weak self] in
                self?.applyShimmerToCapsule()
            }
            return
        }

        guard let label = textLabel else { return }
        label.textColor = .labelColor
        label.stringValue = text
        label.isHidden = false
        refiningLabel?.isHidden = true
        hideWaveform()
    }

    private func applyDownloadAppearance() {
        guard let surface = animationSurfaceView else { return }
        surface.wantsLayer = true
        guard let rootLayer = surface.layer else { return }

        let tint = CALayer()
        tint.frame = surface.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        tint.cornerRadius = cornerRadius
        tint.cornerCurve = .continuous
        tint.masksToBounds = true
        tint.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        tint.borderWidth = 0.75
        tint.borderColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
        rootLayer.insertSublayer(tint, at: 0)
        downloadTintLayer = tint
    }

    func showRecording() {
        displayMode = .normal
        downloadTintLayer?.removeFromSuperlayer()
        downloadTintLayer = nil
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

        let screen = NSScreen.main?.visibleFrame ?? .zero
        var visualFrameRect = panel.frame.insetBy(dx: activeAnimationInset, dy: activeAnimationInset)
        visualFrameRect.size.width = totalWidth
        visualFrameRect.origin.x = screen.midX - totalWidth / 2
        let frame = panelFrame(forVisualFrame: visualFrameRect)

        if animationStyle == "none" {
            panel.setFrame(frame, display: false)
            updateShimmerFrame()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animationStyle == "dynamicIsland" ? 0.16 : 0.2
                ctx.timingFunction = animationStyle == "dynamicIsland"
                    ? CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                    : CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.updateShimmerFrame()
            })
        }
    }

    // MARK: - 全胶囊扫光，仿 iOS 滑动解锁（Full-capsule shimmer, iOS slide-to-unlock style）
    // 用一个 clipLayer（有 cornerRadius + masksToBounds）套住 shimmer 光带（Use a clipLayer with cornerRadius + masksToBounds to wrap the shimmer band）
    // 无论底层是 NSGlassEffectView 还是 NSVisualEffectView，都能精确裁剪为胶囊轮廓（Precisely clips to capsule outline regardless of whether the underlying view is NSGlassEffectView or NSVisualEffectView）

    func applyShimmerToCapsule() {
        guard let cv = animationSurfaceView ?? panel?.contentView else { return }
        cv.wantsLayer = true
        guard let rootLayer = cv.layer else { return }
        stopShimmer()

        let capsuleW = cv.bounds.width
        let bandW: CGFloat = capsuleW * 0.55

        // clipLayer：与胶囊完全重叠，masksToBounds 裁剪子层为胶囊形状（clipLayer: exactly overlaps capsule, masksToBounds clips sublayers to capsule shape）
        let clip = CALayer()
        clip.frame = CGRect(x: 0, y: 0, width: capsuleW, height: capsuleHeight)
        clip.cornerRadius = cornerRadius
        clip.cornerCurve  = .continuous
        clip.masksToBounds = true

        // shimmer 光带：中心高光，两端透明（Shimmer band: center highlight, transparent at both ends）
        let sl = CAGradientLayer()
        sl.frame = CGRect(x: -bandW, y: 0, width: bandW, height: capsuleHeight)
        sl.startPoint = CGPoint(x: 0, y: 0.5)
        sl.endPoint   = CGPoint(x: 1, y: 0.5)
        sl.colors = [
            NSColor.white.withAlphaComponent(0.00).cgColor,
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor,
        ]
        sl.locations = [0.0, 0.5, 1.0] as [NSNumber]

        // position.x 动画：光带从左侧外扫入，扫出右侧，1.6s 循环（position.x animation: band sweeps in from left, out to right, 1.6s loop）
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue   = -bandW / 2
        anim.toValue     = capsuleW + bandW / 2
        anim.duration    = 1.6
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sl.add(anim, forKey: "shimmer")

        clip.addSublayer(sl)
        rootLayer.addSublayer(clip)

        shimmerLayer     = sl
        shimmerClipLayer = clip
    }

    private func updateShimmerFrame() {
        guard let cv = animationSurfaceView ?? panel?.contentView,
              let clip = shimmerClipLayer,
              let sl = shimmerLayer
        else { return }

        let capsuleW = cv.bounds.width
        let bandW = max(1, capsuleW * 0.55)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = CGRect(x: 0, y: 0, width: capsuleW, height: capsuleHeight)
        sl.frame = CGRect(x: -bandW, y: 0, width: bandW, height: capsuleHeight)
        CATransaction.commit()
    }

    func stopShimmer() {
        shimmerLayer?.removeAllAnimations()
        shimmerClipLayer?.removeFromSuperlayer()
        shimmerLayer     = nil
        shimmerClipLayer = nil
    }

    // MARK: - Dismiss

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); return }
        isShowingError = false
        springTimer?.invalidate()
        springTimer = nil
        switch animationStyle {
        case "none":    dismissNone(panel: panel, completion: completion)
        case "minimal": dismissMinimal(panel: panel, completion: completion)
        default:        dismissSpring(panel: panel, completion: completion)
        }
    }

    // MARK: - Spotlight 退场：快速内收 + 淡出 + 模糊增强

    private func dismissSpring(panel: NSPanel, completion: (() -> Void)?) {
        let motion = spotlightMotion
        let container = contentView

        panel.contentView?.wantsLayer = true
        animationSurfaceView?.wantsLayer = true
        animationSurfaceView?.layer?.removeAllAnimations()
        animationSurfaceView?.layer?.transform = CATransform3DIdentity
        container?.layer?.removeAnimation(forKey: "spotlightBlurIn")

        if let container, let blur = CIFilter(name: "CIGaussianBlur") {
            container.wantsLayer = true
            blur.setValue(0.0, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = 0.0
            blurAnim.toValue = spotlightOutBlurRadius
            blurAnim.duration = motion.fadeOut
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurOut")
        }

        let startFrame = panel.frame.insetBy(dx: activeAnimationInset, dy: activeAnimationInset)
        springTimer?.invalidate()
        let startedAt = CACurrentMediaTime()
        let duration = usesSingleBounceSpotlightAnimation ? min(motion.scaleOut, 0.09) : motion.scaleOut
        let dt = spotlightFrameInterval
        springTimer = Timer(timeInterval: dt, repeats: true) { [weak self, weak panel] timer in
            guard let self, let panel, self.panel === panel else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startedAt
            let progress = min(1, CGFloat(elapsed / duration))
            let scale = self.spotlightOutScale(progress: progress, motion: motion)
            panel.setFrame(self.panelFrame(forVisualFrame: self.visualFrame(startFrame, scaledBy: scale)), display: false)
            self.layoutAnimationSurface(in: panel)
            panel.alphaValue = max(0, 1 - CGFloat(elapsed / motion.fadeOut))

            if progress >= 1 {
                timer.invalidate()
                self.springTimer = nil
                panel.alphaValue = 0
                panel.orderOut(nil)
                self.cleanup()
                completion?()
            }
        }
        RunLoop.main.add(springTimer!, forMode: .common)
    }

    // MARK: - 简约模式退场

    private func dismissMinimal(panel: NSPanel, completion: (() -> Void)?) {
        var end = panel.frame; end.origin.y -= 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
            animationSurfaceView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        }, completionHandler: { [weak self] in
            guard let self, self.panel === panel else { return }
            panel.orderOut(nil)
            self.cleanup()
            completion?()
        })
    }

    // MARK: - Debug 计时器

    #if DEBUG_BUILD
    private func startElapsedTimer() {
        recordingStartTime = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed < 60 {
                self.timerLabel?.stringValue = "\(elapsed)s"
            } else {
                self.timerLabel?.stringValue = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            }
        }
        RunLoop.main.add(elapsedTimer!, forMode: .common)
    }
    #endif

    // MARK: - Cleanup

    private func cleanup() {
        panel?.orderOut(nil)
        stopShimmer()
        downloadTintLayer?.removeFromSuperlayer()
        downloadTintLayer = nil
        isShowingError = false
        presentationID += 1
        springTimer?.invalidate()
        springTimer = nil
        #if DEBUG_BUILD
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        timerLabel = nil
        recordingStartTime = nil
        #endif
        waveformView?.stopAnimating()
        waveformView = nil
        textLabel = nil
        refiningLabel = nil
        contentView = nil
        animationSurfaceView = nil
        activeAnimationInset = 0
        waveformVisible = true
        compactStatusKey = nil
        displayMode = .normal
        panel = nil
    }
}
