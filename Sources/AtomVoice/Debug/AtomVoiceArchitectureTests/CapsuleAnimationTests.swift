import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum CapsuleAnimationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Capsule animation selection preserves style compatibility") {
            let defaultSelection = CapsuleAnimationSelection.resolve(styleCode: nil)
            try expect(defaultSelection.style == .spotlight)
            try expect(defaultSelection.appliesSpotlightInset)
            try expect(defaultSelection.usesDynamicFrameCurve)
            try expect(approximatelyEqual(defaultSelection.frameAnimationDuration, 0.16))

            let noneSelection = CapsuleAnimationSelection.resolve(styleCode: "none")
            try expect(noneSelection.style == .none)
            try expect(!noneSelection.appliesSpotlightInset)
            try expect(!noneSelection.usesDynamicFrameCurve)
            try expect(approximatelyEqual(noneSelection.frameAnimationDuration, 0.2))

            let minimalSelection = CapsuleAnimationSelection.resolve(styleCode: "minimal")
            try expect(minimalSelection.style == .minimal)
            try expect(!minimalSelection.appliesSpotlightInset)
            try expect(!minimalSelection.usesDynamicFrameCurve)

            let unknownSelection = CapsuleAnimationSelection.resolve(styleCode: "future")
            try expect(unknownSelection.style == .spotlight)
            try expect(!unknownSelection.appliesSpotlightInset)
            try expect(!unknownSelection.usesDynamicFrameCurve)
        }
        await runner.run("Capsule animation factory creates no-animation strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "none")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleNoneAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }
        await runner.run("Capsule animation factory creates minimal strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "minimal")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleMinimalAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }
        await runner.run("Capsule animation factory creates spotlight inset strategy") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "dynamicIsland")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleSpotlightAnimationStrategy)
            try expect(strategy.currentInset == CapsuleSpotlightAnimationStrategy.defaultInset)
        }
        await runner.run("Capsule animation factory preserves unknown-style no-inset fallback") {
            let selection = CapsuleAnimationSelection.resolve(styleCode: "future")
            let strategy = CapsuleAnimationStrategyFactory.make(selection: selection)

            try expect(strategy is CapsuleSpotlightAnimationStrategy)
            try expect(strategy.currentInset == 0)
        }
        await runner.run("Capsule spotlight motion resolves menu speed values") {
            let medium = CapsuleSpotlightMotion.resolve(speedCode: nil)
            try expect(approximatelyEqual(medium.inScale, 0.78))
            try expect(approximatelyEqual(medium.fadeIn, 0.055))
            try expect(approximatelyEqual(medium.scaleOut, 0.11))

            let slow = CapsuleSpotlightMotion.resolve(speedCode: "slow")
            try expect(approximatelyEqual(slow.inScale, 0.72))
            try expect(approximatelyEqual(slow.fadeOut, 0.14))
            try expect(approximatelyEqual(slow.scaleIn, 0.34))

            let fast = CapsuleSpotlightMotion.resolve(speedCode: "fast")
            try expect(approximatelyEqual(fast.inScale, 0.82))
            try expect(approximatelyEqual(fast.fadeIn, 0.04))
            try expect(approximatelyEqual(fast.scaleOut, 0.09))
        }
        await runner.run("Capsule spotlight keyframes keep entry and exit anchors") {
            let singleStart = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: true)
            try expect(approximatelyEqual(singleStart.width, 1.10))
            try expect(approximatelyEqual(singleStart.height, 0.76))

            let singleEnd = CapsuleSpotlightKeyframes.inScales(progress: 1, singleBounce: true)
            try expect(approximatelyEqual(singleEnd.width, 1.0))
            try expect(approximatelyEqual(singleEnd.height, 1.0))

            let highRefreshStart = CapsuleSpotlightKeyframes.inScales(progress: 0, singleBounce: false)
            try expect(approximatelyEqual(highRefreshStart.width, 1.16))
            try expect(approximatelyEqual(highRefreshStart.height, 0.68))

            let motion = CapsuleSpotlightMotion.resolve(speedCode: "medium")
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.outScale(progress: 0, singleBounce: true, motion: motion), 1.0))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.outScale(progress: 1, singleBounce: true, motion: motion), motion.outScale))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.frameInterval(singleBounce: true), 1.0 / 60.0))
            try expect(approximatelyEqual(CapsuleSpotlightKeyframes.frameInterval(singleBounce: false), 1.0 / 120.0))
        }
        await runner.run("Capsule shimmer geometry derives band and sweep bounds") {
            let geometry = CapsuleShimmerGeometry.make(capsuleWidth: 200, capsuleHeight: 42)
            try expect(approximatelyEqual(geometry.bandWidth, 110))
            try expect(approximatelyEqual(geometry.clipFrame, CGRect(x: 0, y: 0, width: 200, height: 42)))
            try expect(approximatelyEqual(geometry.bandFrame, CGRect(x: -110, y: 0, width: 110, height: 42)))
            try expect(approximatelyEqual(geometry.startPositionX, -55))
            try expect(approximatelyEqual(geometry.endPositionX, 255))

            let minimumGeometry = CapsuleShimmerGeometry.make(capsuleWidth: 0, capsuleHeight: 42, minimumBandWidth: 1)
            try expect(approximatelyEqual(minimumGeometry.bandWidth, 1))
            try expect(approximatelyEqual(minimumGeometry.bandFrame, CGRect(x: -1, y: 0, width: 1, height: 42)))
        }
        await runner.run("Capsule spotlight strategies keep independent state") {
            let first = CapsuleSpotlightAnimationStrategy(currentInset: CapsuleSpotlightAnimationStrategy.defaultInset)
            let second = CapsuleSpotlightAnimationStrategy(currentInset: 0)

            first.springTimer = Timer(timeInterval: 10, repeats: false) { _ in }

            try expect(first.currentInset == CapsuleSpotlightAnimationStrategy.defaultInset)
            try expect(second.currentInset == 0)
            try expect(first.hasActiveTimer)
            try expect(!second.hasActiveTimer)

            first.stop()
            try expect(!first.hasActiveTimer)
            try expect(!second.hasActiveTimer)
        }
        await runner.run("Capsule shimmer strategy reapplies without leaking layers") {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 42))
            view.wantsLayer = true
            let strategy = CapsuleDefaultShimmerStrategy()
            let host = ShimmerHost(animationSurface: view, cornerRadius: 21, capsuleHeight: 42)

            strategy.apply(to: host)
            try expect(strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.count == 1)

            strategy.stop()
            try expect(!strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.isEmpty ?? true)

            strategy.apply(to: host)
            try expect(strategy.hasActiveLayer)
            try expect(view.layer?.sublayers?.count == 1)
            strategy.stop()
            try expect(view.layer?.sublayers?.isEmpty ?? true)
        }
#if DEBUG_BUILD
        await runner.run("Capsule debug elapsed timer stops cleanly") {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 42))
            let strategy = CapsuleDebugElapsedTimerStrategy()

            strategy.start(in: CapsuleElapsedTimerHost(container: container))
            try expect(strategy.isRunning)
            try expect(!container.subviews.isEmpty)

            strategy.stop()
            try expect(!strategy.isRunning)
            try expect(container.subviews.isEmpty)
        }
#endif
    }
}
