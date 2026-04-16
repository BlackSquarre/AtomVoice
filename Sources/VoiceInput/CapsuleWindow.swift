import Cocoa

final class CapsuleWindowController {
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var refiningLabel: NSTextField?
    private var contentView: NSView?
    private var springTimer: Timer?

    private let capsuleHeight: CGFloat = 50
    private let cornerRadius: CGFloat = 25
    private let waveformWidth: CGFloat = 24
    private let waveformLeadingOffset: CGFloat = 8
    private let waveformTextGap: CGFloat = 12
    private let minTextWidth: CGFloat = 144
    private let maxTextWidth: CGFloat = 504
    private let horizontalPadding: CGFloat = 24
    private let pillWidth: CGFloat = 50  // 入场/退场起止小胶囊宽度

    // 弹簧参数根据速度设置动态读取
    private var springParams: (k: CGFloat, c: CGFloat) {
        switch UserDefaults.standard.string(forKey: "animationSpeed") ?? "medium" {
        case "slow":   return (260, 24)   // ~0.7s
        case "fast":   return (600, 42)   // ~0.3s
        default:       return (400, 32)   // ~0.45s（中）
        }
    }

    private var animationStyle: String {
        UserDefaults.standard.string(forKey: "animationStyle") ?? "dynamicIsland"
    }

    // MARK: - 布局计算

    private func fullWidth(forTextWidth tw: CGFloat) -> CGFloat {
        tw + waveformWidth + waveformLeadingOffset + horizontalPadding * 2 + waveformTextGap
    }

    private func targetFrame(width: CGFloat) -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? .zero
        return NSRect(x: s.midX - width / 2, y: s.minY + 54, width: width, height: capsuleHeight)
    }

    // MARK: - Show

    func show() {
        if panel != nil { return }

        let fw = fullWidth(forTextWidth: minTextWidth)
        let target = targetFrame(width: fw)

        let panel = NSPanel(
            contentRect: target,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // 系统阴影自动跟随透明窗口的可见内容轮廓
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.remove(.titled)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let waveform = WaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(waveform)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        container.addSubview(label)

        let refLabel = NSTextField(labelWithString: "优化中...")
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
            glass.style = .regular
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = container
            // none 模式下禁用 glass view 自带的隐式入场动画
            if animationStyle == "none" {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setAnimationDuration(0)
            }
            panel.contentView?.addSubview(glass)
            if animationStyle == "none" {
                CATransaction.commit()
            }
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                glass.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                glass.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: horizontalPadding),
                container.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -horizontalPadding),
                container.topAnchor.constraint(equalTo: glass.topAnchor),
                container.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        } else {
            let fx = NSVisualEffectView(frame: panel.contentView!.bounds)
            fx.autoresizingMask = [.width, .height]
            fx.material = .hudWindow
            fx.state = .active
            fx.blendingMode = .behindWindow
            fx.wantsLayer = true
            fx.layer?.cornerRadius = cornerRadius
            fx.layer?.masksToBounds = true
            fx.layer?.cornerCurve = .continuous
            panel.contentView?.addSubview(fx)
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
            textMinW, textMaxW,
            refLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: waveformTextGap),
            refLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.panel = panel
        self.waveformView = waveform
        self.textLabel = label
        self.refiningLabel = refLabel
        self.contentView = container

        switch animationStyle {
        case "none":    animateInNone(panel: panel, targetFrame: target)
        case "minimal": animateInMinimal(panel: panel, targetFrame: target)
        default:        animateInSpring(panel: panel, container: container, targetFrame: target)
        }
    }

    // MARK: - 灵动岛入场：真实弹簧物理

    private func animateInSpring(panel: NSPanel, container: NSView, targetFrame: NSRect) {
        // 起始：正下方小圆胶囊
        let startFrame = NSRect(
            x: targetFrame.midX - pillWidth / 2,
            y: targetFrame.minY - 20,
            width: pillWidth,
            height: capsuleHeight
        )

        // 内容模糊（被 glass/effect view 圆角裁剪）
        container.wantsLayer = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(12.0, forKey: kCIInputRadiusKey)
        container.layer?.filters = [blur]
        container.layer?.masksToBounds = false

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // 弹簧状态：[x, y, width] 各自独立物理积分
        var sx = startFrame.origin.x, vx: CGFloat = 0
        var sy = startFrame.origin.y, vy: CGFloat = 0
        var sw = startFrame.width,    vw: CGFloat = 0
        let tx = targetFrame.origin.x
        let ty = targetFrame.origin.y
        let tw = targetFrame.width

        let (k, c) = springParams
        let dt: CGFloat = 1.0 / 120.0   // 120Hz 物理更新
        var elapsed: CGFloat = 0
        let maxTime: CGFloat = 1.2       // 超过此时间强制结束

        // 模糊同步消除：用独立 CABasicAnimation，时长略长确保完整清晰
        let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
        blurAnim.fromValue = 12.0
        blurAnim.toValue = 0.0
        blurAnim.duration = 0.5
        blurAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        blurAnim.fillMode = .forwards
        blurAnim.isRemovedOnCompletion = false
        container.layer?.add(blurAnim, forKey: "blurIn")

        springTimer?.invalidate()
        springTimer = Timer(timeInterval: Double(dt), repeats: true) { [weak self] timer in
            guard let self, let panel = self.panel else { timer.invalidate(); return }
            elapsed += dt

            // 弹簧微分方程：a = (-k·Δx - c·v) / m
            func step(_ x: inout CGFloat, _ v: inout CGFloat, _ target: CGFloat) {
                let a = -k * (x - target) - c * v
                v += a * dt
                x += v * dt
            }
            step(&sx, &vx, tx)
            step(&sy, &vy, ty)
            step(&sw, &vw, tw)

            // 淡入：前 150ms 完成
            let alpha = min(1.0, elapsed / 0.15)
            panel.alphaValue = alpha
            panel.setFrame(NSRect(x: sx, y: sy, width: sw, height: self.capsuleHeight), display: false)

            // 判断是否已稳定
            let settled = elapsed > maxTime ||
                (abs(vx) < 0.3 && abs(vy) < 0.3 && abs(vw) < 0.3 &&
                 abs(sx - tx) < 0.3 && abs(sy - ty) < 0.3 && abs(sw - tw) < 0.3)

            if settled {
                timer.invalidate()
                self.springTimer = nil
                panel.setFrame(targetFrame, display: false)
                panel.alphaValue = 1
                container.layer?.filters = nil
                container.layer?.removeAnimation(forKey: "blurIn")
            }
        }
        RunLoop.main.add(springTimer!, forMode: .common)
    }

    // MARK: - 无动画入场

    private func animateInNone(panel: NSPanel, targetFrame: NSRect) {
        // 清空任何残留 filter
        contentView?.layer?.filters = nil
        contentView?.layer?.removeAllAnimations()

        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 1

        // 三重禁用：CATransaction + NSAnimationContext + animator duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.orderFrontRegardless()
        // 强制立即渲染，不等下一 runloop
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
        panel.contentView?.wantsLayer = true
        panel.alphaValue = 0
        var start = targetFrame; start.origin.y -= 8
        panel.setFrame(start, display: false)
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

    // MARK: - Update

    func updateBands(_ bands: [Float]) {
        waveformView?.updateBands(bands)
    }

    func updateText(_ text: String) {
        guard let label = textLabel, let panel = panel else { return }
        label.stringValue = text

        let measured = (text as NSString).size(withAttributes: [.font: label.font!])
        let tw = min(max(measured.width + 18, minTextWidth), maxTextWidth)
        let totalWidth = fullWidth(forTextWidth: tw)

        let screen = NSScreen.main?.visibleFrame ?? .zero
        var frame = panel.frame
        frame.size.width = totalWidth
        frame.origin.x = screen.midX - totalWidth / 2

        if animationStyle == "none" {
            panel.setFrame(frame, display: false)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            })
        }
    }

    func showRefining() {
        textLabel?.isHidden = true
        refiningLabel?.isHidden = false
        waveformView?.stopAnimating()
    }

    // MARK: - Dismiss

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); return }
        springTimer?.invalidate()
        springTimer = nil
        switch animationStyle {
        case "none":    dismissNone(panel: panel, completion: completion)
        case "minimal": dismissMinimal(panel: panel, completion: completion)
        default:        dismissSpring(panel: panel, completion: completion)
        }
    }

    // MARK: - 灵动岛退场：弹簧收缩 + 下移 + 模糊消失

    private func dismissSpring(panel: NSPanel, completion: (() -> Void)?) {
        // 目标：正圆形小胶囊，向下 20pt
        let endFrame = NSRect(
            x: panel.frame.midX - pillWidth / 2,
            y: panel.frame.minY - 20,
            width: pillWidth,
            height: capsuleHeight
        )

        // 模糊增强
        if let container = contentView {
            container.wantsLayer = true
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(0.0, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false
            let ba = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            ba.fromValue = 0.0; ba.toValue = 12.0
            ba.duration = 0.22
            ba.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ba.fillMode = .forwards; ba.isRemovedOnCompletion = false
            container.layer?.add(ba, forKey: "blurOut")
        }

        // 退场用弹簧（阻尼更高=更紧，无回弹）
        let kD: CGFloat = 320, cD: CGFloat = 40
        let dt: CGFloat = 1.0 / 120.0
        var elapsed: CGFloat = 0
        let maxTime: CGFloat = 0.5

        var sx = panel.frame.origin.x, vx: CGFloat = 0
        var sy = panel.frame.origin.y, vy: CGFloat = 0
        var sw = panel.frame.width,    vw: CGFloat = 0
        let tx = endFrame.origin.x, ty = endFrame.origin.y, tw = endFrame.width

        springTimer?.invalidate()
        springTimer = Timer(timeInterval: Double(dt), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += dt

            func step(_ x: inout CGFloat, _ v: inout CGFloat, _ target: CGFloat) {
                let a = -kD * (x - target) - cD * v
                v += a * dt; x += v * dt
            }
            step(&sx, &vx, tx); step(&sy, &vy, ty); step(&sw, &vw, tw)

            let alpha = max(0, 1.0 - elapsed / 0.22)
            panel.alphaValue = alpha
            panel.setFrame(NSRect(x: sx, y: sy, width: sw, height: self.capsuleHeight), display: false)

            let settled = elapsed > maxTime || alpha <= 0
            if settled {
                timer.invalidate()
                self.springTimer = nil
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
            panel.contentView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.cleanup()
            completion?()
        })
    }

    // MARK: - Cleanup

    private func cleanup() {
        springTimer?.invalidate()
        springTimer = nil
        waveformView?.stopAnimating()
        waveformView = nil
        textLabel = nil
        refiningLabel = nil
        contentView = nil
        panel = nil
    }
}
