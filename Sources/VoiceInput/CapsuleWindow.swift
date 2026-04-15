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
    private let waveformWidth: CGFloat = 28   // 紧贴实际竖条宽度（5×3 + 4×2 = 23pt）
    private let waveformTextGap: CGFloat = 14  // 波形→文字间距，更宽松
    private let minTextWidth: CGFloat = 144
    private let maxTextWidth: CGFloat = 504
    private let horizontalPadding: CGFloat = 22  // 左右 padding 加大，视觉居中

    func show() {
        if panel != nil { return }

        let initialWidth: CGFloat = waveformWidth + minTextWidth + horizontalPadding * 2 + waveformTextGap
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

        // 波形视图
        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(waveform)

        // 转录文字标签
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        container.addSubview(label)

        // 优化中指示器
        let refLabel = NSTextField(labelWithString: "优化中...")
        refLabel.translatesAutoresizingMaskIntoConstraints = false
        refLabel.font = .systemFont(ofSize: 12, weight: .regular)
        refLabel.textColor = .secondaryLabelColor
        refLabel.isHidden = true
        container.addSubview(refLabel)

        let textWidth = label.widthAnchor.constraint(greaterThanOrEqualToConstant: minTextWidth)
        let maxWidth  = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth)
        let panelWidth = panel.contentView!.widthAnchor.constraint(equalToConstant: initialWidth)

        // macOS 26：NSGlassEffectView；旧系统：NSVisualEffectView 降级
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            glassView.style = .regular
            glassView.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(glassView)

            // container 作为 glassView 的 contentView
            glassView.contentView = container

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
            waveform.leadingAnchor.constraint(equalTo: container.leadingAnchor),
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

        // 入场动画
        panel.contentView?.wantsLayer = true
        panel.alphaValue = 0
        var startFrame = panel.frame
        startFrame.origin.y -= 8
        panel.setFrame(startFrame, display: false)
        let targetFrame = NSRect(x: x, y: y, width: initialWidth, height: capsuleHeight)
        panel.contentView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
            panel.contentView?.layer?.transform = CATransform3DIdentity
        })
    }

    func updateBands(_ bands: [Float]) {
        waveformView?.updateBands(bands)
    }

    func updateText(_ text: String) {
        guard let label = textLabel, let panel = panel else { return }
        label.stringValue = text

        let textSize = (text as NSString).size(withAttributes: [.font: label.font!])
        let desiredTextWidth = min(max(textSize.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = desiredTextWidth + waveformWidth + horizontalPadding * 2 + waveformTextGap

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

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); return }

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
