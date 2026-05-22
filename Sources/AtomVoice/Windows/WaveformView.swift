import Cocoa

final class WaveformView: NSView {
    // MARK: - Layout
    private let barCount = 5
    private let barWidth: CGFloat  = 3.0   // 5根 × 3 + 4间距 × 2 = 23pt，居中在28pt容器内（5 bars × 3 + 4 gaps × 2 = 23pt, centered in 28pt container）
    private let barSpacing: CGFloat = 2.0
    private let minBarHeight: CGFloat = 3.0
    private let maxBarHeight: CGFloat = 26.0

    // MARK: - 正弦波参数
    // 仅提供缓慢微动，不再让高频细节造成碎跳。（Provides only slow micro-motion, no more high-freq detail causing jitter.）
    private let oscFreqs: [CGFloat]  = [2.8, 3.4, 3.9, 3.2, 2.6]
    private let initPhases: [CGFloat] = [0.0, 2.1, 0.8, 2.9, 1.4]

    // MARK: - 状态
    private var bandLevels: [CGFloat] = [0, 0, 0, 0, 0]   // 来自 FFT 的 5 个频段能量（5 band energy levels from FFT）

    private var barHeights: [CGFloat]
    private var displayTime: CGFloat = 0
    private var isAnimating = false
    private var timer: Timer?
    private var lastTickDate: Date = Date()

    // MARK: - 响应速度
    // attack 快（说话时立刻响应），release 慢（有余韵感）（Attack is fast (responds immediately when speaking), release is slow (has lingering feel)）
    private let attackCoeff:  CGFloat = 0.86   // 开口时马上响应（Responds immediately when speaking）
    private let releaseCoeff: CGFloat = 0.12   // 回落慢一点，保留阻尼和余韵（Falls back slowly, preserving damping and afterglow）
    private let levelDeadband: CGFloat = 0.025  // 吃掉小幅抖动，避免细碎弹跳（Absorbs small jitter, avoids fine bouncing）

    // 待机呼吸幅度（无声时轻微摆动）（Idle breathing amplitude (slight sway when silent)）
    private let idleAmplitude: CGFloat = 0.03

    // MARK: - Init

    override init(frame: NSRect) {
        barHeights = Array(repeating: 3.0, count: 5)
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        barHeights = Array(repeating: 3.0, count: 5)
        super.init(coder: coder)
    }

    deinit { stopAnimating() }

    // MARK: - Public

    /// 接收来自 AudioEngine FFT 的 5 频段能量（0-1）（Receive 5-band energy (0-1) from AudioEngine FFT）
    func updateBands(_ bands: [Float]) {
        for i in 0..<min(bands.count, barCount) {
            let target = filteredLevel(CGFloat(bands[i]), current: bandLevels[i])
            let current = bandLevels[i]
            if target > current {
                bandLevels[i] += (target - current) * attackCoeff
            } else {
                bandLevels[i] += (target - current) * releaseCoeff
            }
        }
    }

    /// 兼容旧的 RMS 接口（全频段同等驱动）（Compatible with legacy RMS interface (all bands driven equally)）
    func updateRMS(_ rms: Float) {
        let level = CGFloat(rms)
        for i in 0..<barCount {
            let current = bandLevels[i]
            let target = filteredLevel(level, current: current)
            if target > current {
                bandLevels[i] += (target - current) * attackCoeff
            } else {
                bandLevels[i] += (target - current) * releaseCoeff
            }
        }
    }

    func stopAnimating() {
        isAnimating = false
        timer?.invalidate()
        timer = nil
        bandLevels     = [0, 0, 0, 0, 0]
        displayTime = 0
        for i in 0..<barCount { barHeights[i] = minBarHeight }
        needsDisplay = true
    }

    func restartAnimating() {
        guard !isAnimating else { return }
        startAnimating()
    }

    // MARK: - Private

    private func startAnimating() {
        isAnimating = true
        lastTickDate = Date()
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isAnimating else { return }
            self.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = Date()
        let dt = CGFloat(now.timeIntervalSince(lastTickDate))
        lastTickDate = now
        displayTime += dt

        for i in 0..<barCount {
            // 正弦波只做轻微调制，真实音量决定主体高度。（Sine wave only provides subtle modulation; real volume determines bar height.）
            let sine = sin(displayTime * oscFreqs[i] + initPhases[i])  // -1…1
            let level = bandLevels[i]

            let pulse = 0.97 + 0.03 * sine
            let quietness = max(0, 1 - level * 5)
            let idle = idleAmplitude * quietness * (0.5 + 0.5 * sine)
            let normalized = min(1, level * pulse + idle)
            let targetHeight = minBarHeight + (maxBarHeight - minBarHeight) * normalized

            // 竖条高度平滑追踪目标（Bar height smoothly tracks target）
            let coeff: CGFloat = targetHeight > barHeights[i] ? 0.46 : 0.16
            barHeights[i] += (targetHeight - barHeights[i]) * coeff
            barHeights[i] = max(minBarHeight, min(maxBarHeight, barHeights[i]))
        }

        needsDisplay = true
    }

    private func filteredLevel(_ target: CGFloat, current: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, target))
        if clamped < 0.015 { return 0 }
        if current < 0.02, clamped > current { return clamped }
        return abs(clamped - current) < levelDeadband ? current : clamped
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2

        // labelColor 自动适配深浅色及玻璃/毛玻璃背景（labelColor auto-adapts to light/dark mode and glass/frosted backgrounds）
        let baseColor: NSColor = .labelColor

        for i in 0..<barCount {
            let h = barHeights[i]
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - h) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            let alpha: CGFloat = 0.5 + 0.5 * ((h - minBarHeight) / (maxBarHeight - minBarHeight))
            ctx.setFillColor(baseColor.withAlphaComponent(alpha).cgColor)
            path.fill()
        }
    }
}
