import Cocoa

enum CapsuleAnimationStyle: Equatable {
    case spotlight
    case minimal
    case none
}

struct CapsuleAnimationSelection: Equatable {
    let style: CapsuleAnimationStyle
    let appliesSpotlightInset: Bool
    let usesDynamicFrameCurve: Bool

    static func resolve(styleCode: String?) -> CapsuleAnimationSelection {
        switch styleCode ?? "dynamicIsland" {
        case "none":
            return CapsuleAnimationSelection(style: .none, appliesSpotlightInset: false, usesDynamicFrameCurve: false)
        case "minimal":
            return CapsuleAnimationSelection(style: .minimal, appliesSpotlightInset: false, usesDynamicFrameCurve: false)
        case "dynamicIsland":
            return CapsuleAnimationSelection(style: .spotlight, appliesSpotlightInset: true, usesDynamicFrameCurve: true)
        default:
            return CapsuleAnimationSelection(style: .spotlight, appliesSpotlightInset: false, usesDynamicFrameCurve: false)
        }
    }

    var frameAnimationDuration: TimeInterval {
        usesDynamicFrameCurve ? 0.16 : 0.2
    }

    var frameTimingFunction: CAMediaTimingFunction {
        usesDynamicFrameCurve
            ? CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            : CAMediaTimingFunction(name: .easeInEaseOut)
    }
}

struct CapsuleSpotlightMotion: Equatable {
    let inScale: CGFloat
    let overshootScale: CGFloat
    let settleScale: CGFloat
    let outScale: CGFloat
    let fadeIn: TimeInterval
    let fadeOut: TimeInterval
    let blurIn: TimeInterval
    let scaleIn: TimeInterval
    let scaleOut: TimeInterval

    static func resolve(speedCode: String?) -> CapsuleSpotlightMotion {
        switch speedCode ?? "medium" {
        case "slow":
            return CapsuleSpotlightMotion(
                inScale: 0.72,
                overshootScale: 1.045,
                settleScale: 0.985,
                outScale: 0.92,
                fadeIn: 0.08,
                fadeOut: 0.14,
                blurIn: 0.18,
                scaleIn: 0.34,
                scaleOut: 0.14
            )
        case "fast":
            return CapsuleSpotlightMotion(
                inScale: 0.82,
                overshootScale: 1.025,
                settleScale: 0.995,
                outScale: 0.94,
                fadeIn: 0.04,
                fadeOut: 0.09,
                blurIn: 0.09,
                scaleIn: 0.20,
                scaleOut: 0.09
            )
        default:
            return CapsuleSpotlightMotion(
                inScale: 0.78,
                overshootScale: 1.035,
                settleScale: 0.99,
                outScale: 0.93,
                fadeIn: 0.055,
                fadeOut: 0.11,
                blurIn: 0.12,
                scaleIn: 0.26,
                scaleOut: 0.11
            )
        }
    }
}

struct CapsuleShimmerGeometry: Equatable {
    let capsuleWidth: CGFloat
    let bandWidth: CGFloat
    let clipFrame: CGRect
    let bandFrame: CGRect
    let startPositionX: CGFloat
    let endPositionX: CGFloat

    static func make(capsuleWidth: CGFloat, capsuleHeight: CGFloat, minimumBandWidth: CGFloat = 0) -> CapsuleShimmerGeometry {
        let bandWidth = max(minimumBandWidth, capsuleWidth * 0.55)
        return CapsuleShimmerGeometry(
            capsuleWidth: capsuleWidth,
            bandWidth: bandWidth,
            clipFrame: CGRect(x: 0, y: 0, width: capsuleWidth, height: capsuleHeight),
            bandFrame: CGRect(x: -bandWidth, y: 0, width: bandWidth, height: capsuleHeight),
            startPositionX: -bandWidth / 2,
            endPositionX: capsuleWidth + bandWidth / 2
        )
    }
}

enum CapsuleSpotlightKeyframes {
    static func visualFrame(_ frame: NSRect, scaledBy scale: CGFloat) -> NSRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    static func visualFrame(_ frame: NSRect, widthScale: CGFloat, heightScale: CGFloat) -> NSRect {
        let width = frame.width * widthScale
        let height = frame.height * heightScale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    static func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    static func easeInCubic(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * t
    }

    static func inScales(progress: CGFloat, singleBounce: Bool) -> (width: CGFloat, height: CGFloat) {
        if singleBounce {
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

    static func outScale(progress: CGFloat, singleBounce: Bool, motion: CapsuleSpotlightMotion) -> CGFloat {
        if singleBounce {
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

    static func frameInterval(singleBounce: Bool) -> TimeInterval {
        singleBounce ? 1.0 / 60.0 : 1.0 / 120.0
    }
}

struct CapsuleAnimationHost {
    let panel: NSPanel
    let container: NSView
    let animationSurface: NSView?
    let waveformView: WaveformView?
    let targetFrame: NSRect
    let presentationID: Int
    let motion: CapsuleSpotlightMotion
    let usesSingleBounceSpotlightAnimation: Bool
    let spotlightFrameInterval: TimeInterval
    let waveformVisible: () -> Bool
    let isCurrent: (NSPanel, Int) -> Bool
    let panelFrame: (NSRect) -> NSRect
    let layoutAnimationSurface: (NSPanel) -> Void
    let cleanup: () -> Void
}

struct CapsuleDismissHost {
    let panel: NSPanel
    let contentView: NSView?
    let animationSurface: NSView?
    let motion: CapsuleSpotlightMotion
    let usesSingleBounceSpotlightAnimation: Bool
    let spotlightFrameInterval: TimeInterval
    let isCurrent: (NSPanel) -> Bool
    let panelFrame: (NSRect) -> NSRect
    let layoutAnimationSurface: (NSPanel) -> Void
    let cleanup: () -> Void
    let completion: (() -> Void)?
}

struct ShimmerHost {
    let animationSurface: NSView
    let cornerRadius: CGFloat
    let capsuleHeight: CGFloat
}

#if DEBUG_BUILD
struct CapsuleElapsedTimerHost {
    let container: NSView
}
#endif

protocol CapsuleAnimationStrategy: AnyObject {
    var currentInset: CGFloat { get }

    func animateIn(host: CapsuleAnimationHost)
    func dismiss(host: CapsuleDismissHost)
    func stop()
}

protocol CapsuleShimmerStrategy: AnyObject {
    func apply(to host: ShimmerHost)
    func updateFrame(in host: ShimmerHost)
    func stop()
}

#if DEBUG_BUILD
protocol CapsuleElapsedTimerStrategy: AnyObject {
    func start(in host: CapsuleElapsedTimerHost)
    func stop()
}
#endif

enum CapsuleAnimationStrategyFactory {
    static func make(selection: CapsuleAnimationSelection) -> any CapsuleAnimationStrategy {
        switch selection.style {
        case .none:
            return CapsuleNoneAnimationStrategy()
        case .minimal:
            return CapsuleMinimalAnimationStrategy()
        case .spotlight:
            let inset = selection.appliesSpotlightInset ? CapsuleSpotlightAnimationStrategy.defaultInset : 0
            return CapsuleSpotlightAnimationStrategy(currentInset: inset)
        }
    }
}

final class CapsuleNoneAnimationStrategy: CapsuleAnimationStrategy {
    let currentInset: CGFloat = 0

    func animateIn(host: CapsuleAnimationHost) {
        host.container.layer?.filters = nil
        host.container.layer?.removeAllAnimations()
        host.container.alphaValue = 1
        host.waveformView?.alphaValue = host.waveformVisible() ? 1 : 0
        if host.waveformVisible() {
            host.waveformView?.restartAnimating()
        } else {
            host.waveformView?.stopAnimating()
        }

        host.panel.setFrame(host.panelFrame(host.targetFrame), display: false)
        host.layoutAnimationSurface(host.panel)
        host.panel.alphaValue = 1

        // 三重禁用：CATransaction + NSAnimationContext + animator duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        host.panel.orderFrontRegardless()
        host.panel.display()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    func dismiss(host: CapsuleDismissHost) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        host.panel.orderOut(nil)
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        host.cleanup()
        host.completion?()
    }

    func stop() {}
}

final class CapsuleMinimalAnimationStrategy: CapsuleAnimationStrategy {
    let currentInset: CGFloat = 0

    func animateIn(host: CapsuleAnimationHost) {
        let currentPresentationID = host.presentationID
        host.panel.contentView?.wantsLayer = true
        host.animationSurface?.wantsLayer = true
        host.panel.alphaValue = 0
        host.container.alphaValue = 0
        var start = host.panelFrame(host.targetFrame)
        start.origin.y -= 8
        host.panel.setFrame(start, display: false)
        host.layoutAnimationSurface(host.panel)
        host.animationSurface?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        host.panel.orderFrontRegardless()

        // 延迟一帧，让 visual effect view 先采样背景
        DispatchQueue.main.async { [weak panel = host.panel, weak container = host.container, weak animationSurface = host.animationSurface, weak waveformView = host.waveformView] in
            guard let panel,
                  host.isCurrent(panel, currentPresentationID)
            else { return }
            if host.waveformVisible() {
                waveformView?.restartAnimating()
            } else {
                waveformView?.stopAnimating()
                waveformView?.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                container?.animator().alphaValue = 1
                waveformView?.animator().alphaValue = host.waveformVisible() ? 1 : 0
                panel.animator().setFrame(host.panelFrame(host.targetFrame), display: true)
                animationSurface?.layer?.transform = CATransform3DIdentity
            })
        }
    }

    func dismiss(host: CapsuleDismissHost) {
        var end = host.panel.frame
        end.origin.y -= 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            host.panel.animator().alphaValue = 0
            host.panel.animator().setFrame(end, display: true)
            host.animationSurface?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        }, completionHandler: { [weak panel = host.panel] in
            guard let panel, host.isCurrent(panel) else { return }
            panel.orderOut(nil)
            host.cleanup()
            host.completion?()
        })
    }

    func stop() {}
}

final class CapsuleSpotlightAnimationStrategy: CapsuleAnimationStrategy {
    static let defaultInset: CGFloat = 18

    let currentInset: CGFloat
    var springTimer: Timer?

    private let inBlurRadius: CGFloat = 14
    private let outBlurRadius: CGFloat = 10

    init(currentInset: CGFloat) {
        self.currentInset = currentInset
    }

    var hasActiveTimer: Bool {
        springTimer != nil
    }

    func animateIn(host: CapsuleAnimationHost) {
        let motion = host.motion
        let initialScales = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: host.usesSingleBounceSpotlightAnimation)
        let initialFrame = CapsuleSpotlightKeyframes.visualFrame(
            host.targetFrame,
            widthScale: initialScales.width,
            heightScale: initialScales.height
        )
        host.panel.setFrame(host.panelFrame(initialFrame), display: false)
        host.panel.alphaValue = 0
        host.container.alphaValue = 0

        host.panel.contentView?.wantsLayer = true
        let surface = host.animationSurface ?? host.panel.contentView
        surface?.wantsLayer = true
        surface?.layer?.masksToBounds = false
        surface?.layer?.transform = CATransform3DIdentity
        host.container.wantsLayer = true
        host.layoutAnimationSurface(host.panel)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(inBlurRadius, forKey: kCIInputRadiusKey)
            host.container.layer?.filters = [blur]
            host.container.layer?.masksToBounds = false
        }

        host.panel.orderFrontRegardless()
        host.panel.invalidateShadow()

        // 延迟一帧，让 glass/effect view 先采样背景，避免首帧白色 fallback
        DispatchQueue.main.async { [weak self, weak panel = host.panel, weak container = host.container, weak waveformView = host.waveformView] in
            guard let self, let panel, let container, host.isCurrent(panel, host.presentationID) else { return }
            if host.waveformVisible() {
                waveformView?.restartAnimating()
            } else {
                waveformView?.stopAnimating()
                waveformView?.alphaValue = 0
            }

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = self.inBlurRadius
            blurAnim.toValue = 0.0
            blurAnim.duration = motion.blurIn
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurIn")

            self.springTimer?.invalidate()
            let startedAt = CACurrentMediaTime()
            let duration = host.usesSingleBounceSpotlightAnimation ? min(motion.scaleIn, 0.22) : motion.scaleIn
            let dt = host.spotlightFrameInterval
            self.springTimer = Timer(timeInterval: dt, repeats: true) { [weak self, weak panel, weak container, weak waveformView] timer in
                guard let self, let panel, let container, host.isCurrent(panel, host.presentationID) else {
                    timer.invalidate()
                    return
                }

                let elapsed = CACurrentMediaTime() - startedAt
                let progress = min(1, CGFloat(elapsed / duration))
                let scales = CapsuleSpotlightKeyframes.inScales(
                    progress: progress,
                    singleBounce: host.usesSingleBounceSpotlightAnimation
                )
                let visualFrame = CapsuleSpotlightKeyframes.visualFrame(
                    host.targetFrame,
                    widthScale: scales.width,
                    heightScale: scales.height
                )
                panel.setFrame(host.panelFrame(visualFrame), display: false)
                host.layoutAnimationSurface(panel)

                panel.alphaValue = min(1, CGFloat(elapsed / motion.fadeIn))
                let contentDelay: TimeInterval = 0.025
                let contentFade = max(0, CGFloat((elapsed - contentDelay) / max(0.001, motion.fadeIn)))
                container.alphaValue = min(1, contentFade)
                waveformView?.alphaValue = host.waveformVisible() ? container.alphaValue : 0

                if progress >= 1 {
                    timer.invalidate()
                    self.springTimer = nil
                    panel.setFrame(host.panelFrame(host.targetFrame), display: false)
                    host.layoutAnimationSurface(panel)
                    panel.alphaValue = 1
                    container.alphaValue = 1
                    waveformView?.alphaValue = host.waveformVisible() ? 1 : 0
                    container.layer?.filters = nil
                    container.layer?.removeAnimation(forKey: "spotlightBlurIn")
                    panel.invalidateShadow()
                }
            }
            if let springTimer = self.springTimer {
                RunLoop.main.add(springTimer, forMode: .default)
            }
        }
    }

    func dismiss(host: CapsuleDismissHost) {
        let motion = host.motion
        let container = host.contentView

        host.panel.contentView?.wantsLayer = true
        host.animationSurface?.wantsLayer = true
        host.animationSurface?.layer?.removeAllAnimations()
        host.animationSurface?.layer?.transform = CATransform3DIdentity
        container?.layer?.removeAnimation(forKey: "spotlightBlurIn")

        if let container, let blur = CIFilter(name: "CIGaussianBlur") {
            container.wantsLayer = true
            blur.setValue(0.0, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = 0.0
            blurAnim.toValue = outBlurRadius
            blurAnim.duration = motion.fadeOut
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurOut")
        }

        let startFrame = host.panel.frame.insetBy(dx: currentInset, dy: currentInset)
        springTimer?.invalidate()
        let startedAt = CACurrentMediaTime()
        let duration = host.usesSingleBounceSpotlightAnimation ? min(motion.scaleOut, 0.09) : motion.scaleOut
        let dt = host.spotlightFrameInterval
        springTimer = Timer(timeInterval: dt, repeats: true) { [weak self, weak panel = host.panel] timer in
            guard let self, let panel, host.isCurrent(panel) else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startedAt
            let progress = min(1, CGFloat(elapsed / duration))
            let scale = CapsuleSpotlightKeyframes.outScale(
                progress: progress,
                singleBounce: host.usesSingleBounceSpotlightAnimation,
                motion: motion
            )
            let visualFrame = CapsuleSpotlightKeyframes.visualFrame(startFrame, scaledBy: scale)
            panel.setFrame(host.panelFrame(visualFrame), display: false)
            host.layoutAnimationSurface(panel)
            panel.alphaValue = max(0, 1 - CGFloat(elapsed / motion.fadeOut))

            if progress >= 1 {
                timer.invalidate()
                self.springTimer = nil
                panel.alphaValue = 0
                panel.orderOut(nil)
                host.cleanup()
                host.completion?()
            }
        }
        if let springTimer {
            RunLoop.main.add(springTimer, forMode: .default)
        }
    }

    func stop() {
        springTimer?.invalidate()
        springTimer = nil
    }
}

final class CapsuleDefaultShimmerStrategy: CapsuleShimmerStrategy {
    private(set) var shimmerLayer: CAGradientLayer?
    private(set) var shimmerClipLayer: CALayer?

    var hasActiveLayer: Bool {
        shimmerLayer != nil || shimmerClipLayer != nil
    }

    func apply(to host: ShimmerHost) {
        let cv = host.animationSurface
        cv.wantsLayer = true
        guard let rootLayer = cv.layer else { return }
        stop()

        let geometry = CapsuleShimmerGeometry.make(capsuleWidth: cv.bounds.width, capsuleHeight: host.capsuleHeight)

        // clipLayer 与胶囊完全重叠，负责把光带裁剪成胶囊形状
        let clip = CALayer()
        clip.frame = geometry.clipFrame
        clip.cornerRadius = host.cornerRadius
        clip.cornerCurve = .continuous
        clip.masksToBounds = true

        // shimmer 光带：中心高光，两端透明
        let sl = CAGradientLayer()
        sl.frame = geometry.bandFrame
        sl.startPoint = CGPoint(x: 0, y: 0.5)
        sl.endPoint = CGPoint(x: 1, y: 0.5)
        sl.colors = [
            NSColor.white.withAlphaComponent(0.00).cgColor,
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor,
        ]
        sl.locations = [0.0, 0.5, 1.0] as [NSNumber]

        // position.x 动画：光带从左侧外扫入，扫出右侧，1.6s 循环
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = geometry.startPositionX
        anim.toValue = geometry.endPositionX
        anim.duration = 1.6
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sl.add(anim, forKey: "shimmer")

        clip.addSublayer(sl)
        rootLayer.addSublayer(clip)

        shimmerLayer = sl
        shimmerClipLayer = clip
    }

    func updateFrame(in host: ShimmerHost) {
        guard let clip = shimmerClipLayer,
              let sl = shimmerLayer
        else { return }

        let geometry = CapsuleShimmerGeometry.make(
            capsuleWidth: host.animationSurface.bounds.width,
            capsuleHeight: host.capsuleHeight,
            minimumBandWidth: 1
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = geometry.clipFrame
        sl.frame = geometry.bandFrame
        CATransaction.commit()
    }

    func stop() {
        shimmerLayer?.removeAllAnimations()
        shimmerClipLayer?.removeFromSuperlayer()
        shimmerLayer = nil
        shimmerClipLayer = nil
    }
}

#if DEBUG_BUILD
final class CapsuleDebugElapsedTimerStrategy: CapsuleElapsedTimerStrategy {
    private var timerLabel: NSTextField?
    private var elapsedTimer: Timer?
    private var recordingStartTime: Date?
    private let timerLabelWidth: CGFloat = 34

    var isRunning: Bool {
        elapsedTimer != nil
    }

    func start(in host: CapsuleElapsedTimerHost) {
        stop()

        // 计时器标签：作为底层半透明叠层显示在右侧，不占据布局宽度
        // (Timer label: shown as a translucent underlay on the right; takes no layout width.)
        let timerLbl = NSTextField(labelWithString: "0s")
        timerLbl.translatesAutoresizingMaskIntoConstraints = false
        timerLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timerLbl.textColor = .tertiaryLabelColor
        timerLbl.alphaValue = 0.55
        timerLbl.alignment = .right
        // 放在所有子视图最底层，文字变长时会盖住计时器（Place beneath all siblings so long recognized text covers it.）
        host.container.addSubview(timerLbl, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            timerLbl.trailingAnchor.constraint(equalTo: host.container.trailingAnchor),
            timerLbl.centerYAnchor.constraint(equalTo: host.container.centerYAnchor),
            timerLbl.widthAnchor.constraint(equalToConstant: timerLabelWidth),
        ])

        timerLabel = timerLbl
        recordingStartTime = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed < 60 {
                self.timerLabel?.stringValue = "\(elapsed)s"
            } else {
                self.timerLabel?.stringValue = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            }
        }
        if let elapsedTimer {
            RunLoop.main.add(elapsedTimer, forMode: .default)
        }
    }

    func stop() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        timerLabel?.removeFromSuperview()
        timerLabel = nil
        recordingStartTime = nil
    }
}
#endif

extension CapsuleWindowController {
    var currentAnimationSelection: CapsuleAnimationSelection {
        CapsuleAnimationSelection.resolve(styleCode: AppSettings.animationStyle)
    }

    var spotlightMotion: CapsuleSpotlightMotion {
        CapsuleSpotlightMotion.resolve(speedCode: AppSettings.animationSpeed)
    }

    var usesSingleBounceSpotlightAnimation: Bool {
        (NSScreen.main?.maximumFramesPerSecond ?? 60) <= 60
    }

    var spotlightFrameInterval: TimeInterval {
        CapsuleSpotlightKeyframes.frameInterval(singleBounce: usesSingleBounceSpotlightAnimation)
    }

    func layoutAnimationSurface(in panel: NSPanel) {
        guard let surface = animationSurfaceView, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let frame = host.bounds.insetBy(dx: animationInset, dy: animationInset)

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

    func animateFrameChange(
        panel: NSPanel,
        frame: NSRect,
        currentPresentationID: Int,
        completion: (() -> Void)? = nil
    ) {
        let selection = currentAnimationSelection
        if selection.style == .none {
            panel.setFrame(frame, display: false)
            updateShimmerFrame()
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = selection.frameAnimationDuration
            ctx.timingFunction = selection.frameTimingFunction
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

    // MARK: - 全胶囊扫光，仿 iOS 滑动解锁

    func applyShimmerToCapsule() {
        guard let host = makeShimmerHost() else { return }
        shimmerStrategy.apply(to: host)
    }

    func updateShimmerFrame() {
        guard let host = makeShimmerHost() else { return }
        shimmerStrategy.updateFrame(in: host)
    }

    func stopShimmer() {
        shimmerStrategy.stop()
    }

    #if DEBUG_BUILD
    func startElapsedTimer(in container: NSView) {
        elapsedTimerStrategy.start(in: CapsuleElapsedTimerHost(container: container))
    }
    #endif
}
