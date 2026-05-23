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

protocol CapsuleAnimationStrategy {
    func animateIn(
        controller: CapsuleWindowController,
        panel: NSPanel,
        container: NSView,
        targetFrame: NSRect
    )

    func dismiss(
        controller: CapsuleWindowController,
        panel: NSPanel,
        completion: (() -> Void)?
    )
}

protocol CapsuleShimmerStrategy {
    func apply(to controller: CapsuleWindowController)
    func updateFrame(in controller: CapsuleWindowController)
    func stop(in controller: CapsuleWindowController)
}

#if DEBUG_BUILD
protocol CapsuleElapsedTimerStrategy {
    func start(in controller: CapsuleWindowController)
}
#endif

private struct CapsuleNoneAnimationStrategy: CapsuleAnimationStrategy {
    func animateIn(controller: CapsuleWindowController, panel: NSPanel, container: NSView, targetFrame: NSRect) {
        controller.contentView?.layer?.filters = nil
        controller.contentView?.layer?.removeAllAnimations()
        controller.contentView?.alphaValue = 1
        controller.waveformView?.alphaValue = controller.waveformVisible ? 1 : 0
        if controller.waveformVisible {
            controller.waveformView?.restartAnimating()
        } else {
            controller.waveformView?.stopAnimating()
        }

        panel.setFrame(controller.panelFrame(forVisualFrame: targetFrame), display: false)
        controller.layoutAnimationSurface(in: panel)
        panel.alphaValue = 1

        // 三重禁用：CATransaction + NSAnimationContext + animator duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.orderFrontRegardless()
        panel.display()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    func dismiss(controller: CapsuleWindowController, panel: NSPanel, completion: (() -> Void)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.orderOut(nil)
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        controller.cleanup()
        completion?()
    }
}

private struct CapsuleMinimalAnimationStrategy: CapsuleAnimationStrategy {
    func animateIn(controller: CapsuleWindowController, panel: NSPanel, container: NSView, targetFrame: NSRect) {
        let currentPresentationID = controller.presentationID
        panel.contentView?.wantsLayer = true
        controller.animationSurfaceView?.wantsLayer = true
        panel.alphaValue = 0
        controller.contentView?.alphaValue = 0
        var start = controller.panelFrame(forVisualFrame: targetFrame)
        start.origin.y -= 8
        panel.setFrame(start, display: false)
        controller.layoutAnimationSurface(in: panel)
        controller.animationSurfaceView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        panel.orderFrontRegardless()

        // 延迟一帧，让 visual effect view 先采样背景
        DispatchQueue.main.async { [weak controller] in
            guard let controller,
                  controller.panel === panel,
                  controller.presentationID == currentPresentationID
            else { return }
            if controller.waveformVisible {
                controller.waveformView?.restartAnimating()
            } else {
                controller.waveformView?.stopAnimating()
                controller.waveformView?.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                controller.contentView?.animator().alphaValue = 1
                controller.waveformView?.animator().alphaValue = controller.waveformVisible ? 1 : 0
                panel.animator().setFrame(controller.panelFrame(forVisualFrame: targetFrame), display: true)
                controller.animationSurfaceView?.layer?.transform = CATransform3DIdentity
            })
        }
    }

    func dismiss(controller: CapsuleWindowController, panel: NSPanel, completion: (() -> Void)?) {
        var end = panel.frame
        end.origin.y -= 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
            controller.animationSurfaceView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1.0)
        }, completionHandler: { [weak controller] in
            guard let controller, controller.panel === panel else { return }
            panel.orderOut(nil)
            controller.cleanup()
            completion?()
        })
    }
}

private struct CapsuleSpotlightAnimationStrategy: CapsuleAnimationStrategy {
    func animateIn(controller: CapsuleWindowController, panel: NSPanel, container: NSView, targetFrame: NSRect) {
        let motion = controller.spotlightMotion
        let initialScales = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: controller.usesSingleBounceSpotlightAnimation)
        let initialFrame = CapsuleSpotlightKeyframes.visualFrame(
            targetFrame,
            widthScale: initialScales.width,
            heightScale: initialScales.height
        )
        panel.setFrame(controller.panelFrame(forVisualFrame: initialFrame), display: false)
        panel.alphaValue = 0
        container.alphaValue = 0

        panel.contentView?.wantsLayer = true
        let surface = controller.animationSurfaceView ?? panel.contentView
        surface?.wantsLayer = true
        surface?.layer?.masksToBounds = false
        surface?.layer?.transform = CATransform3DIdentity
        container.wantsLayer = true
        controller.layoutAnimationSurface(in: panel)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(controller.spotlightInBlurRadius, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false
        }

        panel.orderFrontRegardless()
        panel.invalidateShadow()

        // 延迟一帧，让 glass/effect view 先采样背景，避免首帧白色 fallback
        DispatchQueue.main.async { [weak controller, weak panel] in
            guard let controller, let panel, controller.panel === panel else { return }
            if controller.waveformVisible {
                controller.waveformView?.restartAnimating()
            } else {
                controller.waveformView?.stopAnimating()
                controller.waveformView?.alphaValue = 0
            }

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = controller.spotlightInBlurRadius
            blurAnim.toValue = 0.0
            blurAnim.duration = motion.blurIn
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurIn")

            controller.springTimer?.invalidate()
            let startedAt = CACurrentMediaTime()
            let duration = controller.usesSingleBounceSpotlightAnimation ? min(motion.scaleIn, 0.22) : motion.scaleIn
            let dt = controller.spotlightFrameInterval
            controller.springTimer = Timer(timeInterval: dt, repeats: true) { [weak controller, weak panel] timer in
                guard let controller, let panel, controller.panel === panel else {
                    timer.invalidate()
                    return
                }

                let elapsed = CACurrentMediaTime() - startedAt
                let progress = min(1, CGFloat(elapsed / duration))
                let scales = CapsuleSpotlightKeyframes.inScales(
                    progress: progress,
                    singleBounce: controller.usesSingleBounceSpotlightAnimation
                )
                let visualFrame = CapsuleSpotlightKeyframes.visualFrame(
                    targetFrame,
                    widthScale: scales.width,
                    heightScale: scales.height
                )
                panel.setFrame(controller.panelFrame(forVisualFrame: visualFrame), display: false)
                controller.layoutAnimationSurface(in: panel)

                panel.alphaValue = min(1, CGFloat(elapsed / motion.fadeIn))
                let contentDelay: TimeInterval = 0.025
                let contentFade = max(0, CGFloat((elapsed - contentDelay) / max(0.001, motion.fadeIn)))
                container.alphaValue = min(1, contentFade)
                controller.waveformView?.alphaValue = controller.waveformVisible ? container.alphaValue : 0

                if progress >= 1 {
                    timer.invalidate()
                    controller.springTimer = nil
                    panel.setFrame(controller.panelFrame(forVisualFrame: targetFrame), display: false)
                    controller.layoutAnimationSurface(in: panel)
                    panel.alphaValue = 1
                    container.alphaValue = 1
                    controller.waveformView?.alphaValue = controller.waveformVisible ? 1 : 0
                    container.layer?.filters = nil
                    container.layer?.removeAnimation(forKey: "spotlightBlurIn")
                    panel.invalidateShadow()
                }
            }
            RunLoop.main.add(controller.springTimer!, forMode: .default)
        }
    }

    func dismiss(controller: CapsuleWindowController, panel: NSPanel, completion: (() -> Void)?) {
        let motion = controller.spotlightMotion
        let container = controller.contentView

        panel.contentView?.wantsLayer = true
        controller.animationSurfaceView?.wantsLayer = true
        controller.animationSurfaceView?.layer?.removeAllAnimations()
        controller.animationSurfaceView?.layer?.transform = CATransform3DIdentity
        container?.layer?.removeAnimation(forKey: "spotlightBlurIn")

        if let container, let blur = CIFilter(name: "CIGaussianBlur") {
            container.wantsLayer = true
            blur.setValue(0.0, forKey: kCIInputRadiusKey)
            container.layer?.filters = [blur]
            container.layer?.masksToBounds = false

            let blurAnim = CABasicAnimation(keyPath: "filters.CIGaussianBlur.inputRadius")
            blurAnim.fromValue = 0.0
            blurAnim.toValue = controller.spotlightOutBlurRadius
            blurAnim.duration = motion.fadeOut
            blurAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            blurAnim.fillMode = .forwards
            blurAnim.isRemovedOnCompletion = false
            container.layer?.add(blurAnim, forKey: "spotlightBlurOut")
        }

        let startFrame = panel.frame.insetBy(dx: controller.activeAnimationInset, dy: controller.activeAnimationInset)
        controller.springTimer?.invalidate()
        let startedAt = CACurrentMediaTime()
        let duration = controller.usesSingleBounceSpotlightAnimation ? min(motion.scaleOut, 0.09) : motion.scaleOut
        let dt = controller.spotlightFrameInterval
        controller.springTimer = Timer(timeInterval: dt, repeats: true) { [weak controller, weak panel] timer in
            guard let controller, let panel, controller.panel === panel else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startedAt
            let progress = min(1, CGFloat(elapsed / duration))
            let scale = CapsuleSpotlightKeyframes.outScale(
                progress: progress,
                singleBounce: controller.usesSingleBounceSpotlightAnimation,
                motion: motion
            )
            let visualFrame = CapsuleSpotlightKeyframes.visualFrame(startFrame, scaledBy: scale)
            panel.setFrame(controller.panelFrame(forVisualFrame: visualFrame), display: false)
            controller.layoutAnimationSurface(in: panel)
            panel.alphaValue = max(0, 1 - CGFloat(elapsed / motion.fadeOut))

            if progress >= 1 {
                timer.invalidate()
                controller.springTimer = nil
                panel.alphaValue = 0
                panel.orderOut(nil)
                controller.cleanup()
                completion?()
            }
        }
        RunLoop.main.add(controller.springTimer!, forMode: .default)
    }
}

private struct CapsuleDefaultShimmerStrategy: CapsuleShimmerStrategy {
    func apply(to controller: CapsuleWindowController) {
        guard let cv = controller.animationSurfaceView ?? controller.panel?.contentView else { return }
        cv.wantsLayer = true
        guard let rootLayer = cv.layer else { return }
        stop(in: controller)

        let geometry = CapsuleShimmerGeometry.make(capsuleWidth: cv.bounds.width, capsuleHeight: controller.capsuleHeight)

        // clipLayer 与胶囊完全重叠，负责把光带裁剪成胶囊形状
        let clip = CALayer()
        clip.frame = geometry.clipFrame
        clip.cornerRadius = controller.cornerRadius
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

        controller.shimmerLayer = sl
        controller.shimmerClipLayer = clip
    }

    func updateFrame(in controller: CapsuleWindowController) {
        guard let cv = controller.animationSurfaceView ?? controller.panel?.contentView,
              let clip = controller.shimmerClipLayer,
              let sl = controller.shimmerLayer
        else { return }

        let geometry = CapsuleShimmerGeometry.make(
            capsuleWidth: cv.bounds.width,
            capsuleHeight: controller.capsuleHeight,
            minimumBandWidth: 1
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = geometry.clipFrame
        sl.frame = geometry.bandFrame
        CATransaction.commit()
    }

    func stop(in controller: CapsuleWindowController) {
        controller.shimmerLayer?.removeAllAnimations()
        controller.shimmerClipLayer?.removeFromSuperlayer()
        controller.shimmerLayer = nil
        controller.shimmerClipLayer = nil
    }
}

#if DEBUG_BUILD
private struct CapsuleDebugElapsedTimerStrategy: CapsuleElapsedTimerStrategy {
    func start(in controller: CapsuleWindowController) {
        controller.recordingStartTime = Date()
        controller.elapsedTimer?.invalidate()
        controller.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak controller] _ in
            guard let controller, let start = controller.recordingStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed < 60 {
                controller.timerLabel?.stringValue = "\(elapsed)s"
            } else {
                controller.timerLabel?.stringValue = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            }
        }
        RunLoop.main.add(controller.elapsedTimer!, forMode: .default)
    }
}
#endif

extension CapsuleWindowController {
    var currentAnimationSelection: CapsuleAnimationSelection {
        CapsuleAnimationSelection.resolve(styleCode: UserDefaults.standard.string(forKey: "animationStyle"))
    }

    var currentAnimationStyle: CapsuleAnimationStyle {
        currentAnimationSelection.style
    }

    var currentAnimationStrategy: any CapsuleAnimationStrategy {
        switch currentAnimationStyle {
        case .none:
            return CapsuleNoneAnimationStrategy()
        case .minimal:
            return CapsuleMinimalAnimationStrategy()
        case .spotlight:
            return CapsuleSpotlightAnimationStrategy()
        }
    }

    var shimmerStrategy: any CapsuleShimmerStrategy {
        CapsuleDefaultShimmerStrategy()
    }

    #if DEBUG_BUILD
    var elapsedTimerStrategy: any CapsuleElapsedTimerStrategy {
        CapsuleDebugElapsedTimerStrategy()
    }
    #endif

    var spotlightMotion: CapsuleSpotlightMotion {
        CapsuleSpotlightMotion.resolve(speedCode: UserDefaults.standard.string(forKey: "animationSpeed"))
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
        shimmerStrategy.apply(to: self)
    }

    func updateShimmerFrame() {
        shimmerStrategy.updateFrame(in: self)
    }

    func stopShimmer() {
        shimmerStrategy.stop(in: self)
    }

    #if DEBUG_BUILD
    func startElapsedTimer() {
        elapsedTimerStrategy.start(in: self)
    }
    #endif
}
