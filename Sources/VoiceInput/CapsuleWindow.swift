import Cocoa

final class CapsuleWindowController {
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var refiningLabel: NSTextField?
    private var contentView: NSView?
    private var textWidthConstraint: NSLayoutConstraint?
    private var panelWidthConstraint: NSLayoutConstraint?

    private let capsuleHeight: CGFloat = 50
    private let cornerRadius: CGFloat = 25
    private let waveformWidth: CGFloat = 24
    private let waveformLeadingOffset: CGFloat = 8
    private let waveformTextGap: CGFloat = 12
    private let minTextWidth: CGFloat = 144
    private let maxTextWidth: CGFloat = 504
    private let horizontalPadding: CGFloat = 24

    // MARK: - 动画模式

    private var isDynamicIsland: Bool {
        UserDefaults.standard.string(forKey: "animationStyle") != "minimal"
    }

    // MARK: - Show

    func show() {
        if panel != nil { return }

        let initialWidth: CGFloat = waveformWidth + waveformLeadingOffset + minTextWidth + horizontalPadding * 2 + waveformTextGap
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let x = screenFrame.midX - initialWidth / 2
        let y = screenFrame.minY + 54

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: initialWidth, height: capsuleHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.remove(.titled)

        // 内容容器
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(waveform)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        container.addSubview(label)

        let refLabel = NSTextField(labelWithString: "优化中...")
        refLabel.translatesAutoresizingMaskIntoConstraints = false
        refLabel.font = .systemFont(ofSize: 12, weight: .regular)
        refLabel.textColor = .secondaryLabelColor
        refLabel.isHidden = true
        container.addSubview(refLabel)

        let textWidth  = label.widthAnchor.constraint(greaterThanOrEqualToConstant: minTextWidth)
        let maxWidth   = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth)
        let panelWidth = panel.contentView!.widthAnchor.constraint(equalToConstant: initialWidth)

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            glassView.style = .regular
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.contentView = container
            panel.contentView?.addSubview(glassView)
            NSLayoutConstraint.activate([
                glassView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                glassView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                glassView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: horizontalPadding),
                container.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -horizontalPadding),
                container.topAnchor.constraint(equalTo: glassView.topAnchor),
                container.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
            ])
        } else {
            let effectView = NSVisualEffectView(frame: panel.contentView!.bounds)
            effectView.autoresizingMask = [.width, .height]
            effectView.material = .hudWindow
            effectView.state = .active
            effectView.blendingMode = .behindWindow
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = cornerRadius
            effectView.layer?.masksToBounds = true
            effectView.layer?.cornerCurve = .continuous
            panel.contentView?.addSubview(effectView)
            panel.contentView?.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: horizontalPadding),
                container.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -horizontalPadding),
                container.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                container.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: waveformLeadingOffset),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformWidth),
            waveform.heightAnchor.constraint(equalToConstant: 29),
            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textWidth, maxWidth,
            refLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
            refLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            panelWidth,
        ])

        self.panel = panel
        self.waveformView = waveform
        self.textLabel = label
        self.refiningLabel = refLabel
        self.contentView = container
        self.textWidthConstraint = textWidth
        self.panelWidthConstraint = panelWidth

        panel.contentView?.wantsLayer = true
        panel.orderFrontRegardless()

        if isDynamicIsland {
            animateInDynamicIsland(panel: panel, targetFrame: NSRect(x: x, y: y, width: initialWidth, height: capsuleHeight))
        } else {
            animateInMinimal(panel: panel, targetFrame: NSRect(x: x, y: y, width: initialWidth, height: capsuleHeight))
        }
    }

    // MARK: - 灵动岛入场：弹簧缩放 + 高斯模糊淡入

    private func animateInDynamicIsland(panel: NSPanel, targetFrame: NSRect) {
        guard let layer = panel.contentView?.layer else { return }

        // 初始状态：缩小 + 完全透明
        panel.alphaValue = 0
        layer.transform = CATransform3DMakeScale(0.55, 0.55, 1.0)
        layer.masksToBounds = false

        // 添加高斯模糊滤镜（从模糊开始）
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(16.0, forKey: kCIInputRadiusKey)
        layer.filters = [blur]

        panel.setFrame(targetFrame, display: false)

        // 1. 模糊消除动画（独立 CAAnimation，更精准）
        let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
        blurAnim.fromValue = 16.0
        blurAnim.toValue = 0.0
        blurAnim.duration = 0.45
        blurAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        blurAnim.fillMode = .forwards
        blurAnim.isRemovedOnCompletion = false
        layer.add(blurAnim, forKey: "blurIn")

        // 2. 弹簧缩放 + 淡入（spring timing 产生自然回弹）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0) // spring
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            layer.transform = CATransform3DIdentity
        }, completionHandler: {
            // 动画结束后移除滤镜，避免影响后续渲染
            layer.filters = nil
            layer.removeAnimation(forKey: "blurIn")
        })
    }

    // MARK: - 简约模式入场：滑入 + 缩放

    private func animateInMinimal(panel: NSPanel, targetFrame: NSRect) {
        guard let layer = panel.contentView?.layer else { return }
        panel.alphaValue = 0
        var startFrame = targetFrame
        startFrame.origin.y -= 8
        panel.setFrame(startFrame, display: false)
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
            layer.transform = CATransform3DIdentity
        })
    }

    // MARK: - Update

    func updateBands(_ bands: [Float]) {
        waveformView?.updateBands(bands)
    }

    func updateText(_ text: String) {
        guard let label = textLabel, let panel = panel else { return }
        label.stringValue = text

        let textSize = (text as NSString).size(withAttributes: [.font: label.font!])
        let desiredTextWidth = min(max(textSize.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = desiredTextWidth + waveformWidth + waveformLeadingOffset + horizontalPadding * 2 + waveformTextGap

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panelWidthConstraint?.animator().constant = totalWidth
            let screenFrame = NSScreen.main?.visibleFrame ?? .zero
            var frame = panel.frame
            frame.size.width = totalWidth
            frame.origin.x = screenFrame.midX - totalWidth / 2
            panel.animator().setFrame(frame, display: true)
        })
    }

    func showRefining() {
        textLabel?.isHidden = true
        refiningLabel?.isHidden = false
        waveformView?.stopAnimating()
    }

    // MARK: - Dismiss

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); return }

        if isDynamicIsland {
            dismissDynamicIsland(panel: panel, completion: completion)
        } else {
            dismissMinimal(panel: panel, completion: completion)
        }
    }

    // MARK: - 灵动岛退场：弹簧缩小 + 高斯模糊消失

    private func dismissDynamicIsland(panel: NSPanel, completion: (() -> Void)?) {
        guard let layer = panel.contentView?.layer else {
            panel.orderOut(nil); cleanup(); completion?(); return
        }

        layer.masksToBounds = false
        // 恢复初始无模糊状态（如果上次动画残留）
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(0.0, forKey: kCIInputRadiusKey)
        layer.filters = [blur]

        // 模糊增强动画
        let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
        blurAnim.fromValue = 0.0
        blurAnim.toValue = 14.0
        blurAnim.duration = 0.28
        blurAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        blurAnim.fillMode = .forwards
        blurAnim.isRemovedOnCompletion = false
        layer.add(blurAnim, forKey: "blurOut")

        // 缩小 + 淡出
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            layer.transform = CATransform3DMakeScale(0.55, 0.55, 1.0)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.cleanup()
            completion?()
        })
    }

    // MARK: - 简约模式退场：滑出 + 缩放

    private func dismissMinimal(panel: NSPanel, completion: (() -> Void)?) {
        var targetFrame = panel.frame
        targetFrame.origin.y -= 8

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
            panel.contentView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.cleanup()
            completion?()
        })
    }

    // MARK: - Cleanup

    private func cleanup() {
        waveformView?.stopAnimating()
        waveformView = nil
        textLabel = nil
        refiningLabel = nil
        contentView = nil
        textWidthConstraint = nil
        panelWidthConstraint = nil
        panel = nil
    }
}
