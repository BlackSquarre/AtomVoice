import Cocoa

final class CapsuleWindowController {
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var refiningLabel: NSTextField?
    private var contentView: NSView?
    private var textWidthConstraint: NSLayoutConstraint?
    private var panelWidthConstraint: NSLayoutConstraint?

    // 缩小 10%: 56 * 0.9 ≈ 50, 28 * 0.9 = 25, 44 * 0.9 ≈ 40, etc.
    private let capsuleHeight: CGFloat = 50
    private let cornerRadius: CGFloat = 25
    private let waveformWidth: CGFloat = 40
    private let minTextWidth: CGFloat = 144  // 160 * 0.9
    private let maxTextWidth: CGFloat = 504  // 560 * 0.9
    private let horizontalPadding: CGFloat = 18

    func show() {
        if panel != nil { return }

        let initialWidth: CGFloat = waveformWidth + minTextWidth + horizontalPadding * 3
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

        // 毛玻璃背景 — 自动适配深色/浅色模式
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

        // 内容容器
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(container)

        // 波形视图
        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(waveform)

        // 转录文字标签 — 使用 labelColor 自动适配深浅色
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        container.addSubview(label)

        // "优化中..." 指示器
        let refLabel = NSTextField(labelWithString: "优化中...")
        refLabel.translatesAutoresizingMaskIntoConstraints = false
        refLabel.font = .systemFont(ofSize: 12, weight: .regular)
        refLabel.textColor = .secondaryLabelColor
        refLabel.isHidden = true
        container.addSubview(refLabel)

        let textWidth = label.widthAnchor.constraint(greaterThanOrEqualToConstant: minTextWidth)
        let maxWidth = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth)
        let panelWidth = panel.contentView!.widthAnchor.constraint(equalToConstant: initialWidth)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: horizontalPadding),
            container.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -horizontalPadding),
            container.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),

            waveform.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformWidth),
            waveform.heightAnchor.constraint(equalToConstant: 29),  // 32 * 0.9

            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textWidth,
            maxWidth,

            refLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: 10),
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

        // 入场动画: 从底部滑入 + 缩放 + 淡入, 0.2s
        panel.contentView?.wantsLayer = true
        panel.alphaValue = 0

        // 起始位置向下偏移 8pt
        var startFrame = panel.frame
        startFrame.origin.y -= 8
        panel.setFrame(startFrame, display: false)

        let targetFrame = NSRect(x: x, y: y, width: initialWidth, height: capsuleHeight)

        // 起始缩放
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

    func updateRMS(_ rms: Float) {
        waveformView?.updateRMS(rms)
    }

    func updateText(_ text: String) {
        guard let label = textLabel, let panel = panel else { return }
        label.stringValue = text

        let textSize = (text as NSString).size(withAttributes: [.font: label.font!])
        let desiredTextWidth = min(max(textSize.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = desiredTextWidth + waveformWidth + horizontalPadding * 3 + 10

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
        guard let panel = panel else {
            completion?()
            return
        }

        // 退场动画: 向下滑出 + 缩放 + 淡出, 0.2s
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
