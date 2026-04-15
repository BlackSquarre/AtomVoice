import Cocoa

final class WaveformView: NSView {
    // MARK: - Layout
    private let barCount = 5
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 2.8
    private let minBarHeight: CGFloat = 3.0
    private let maxBarHeight: CGFloat = 26.0

    // MARK: - 正弦波参数（每根竖条独立频率/相位，Apple Music 风格）
    // 频率单位：弧度/秒，各竖条互质，避免周期对齐产生机械感
    private let frequencies: [CGFloat] = [2.1, 3.4, 2.7, 4.1, 1.8]
    // 初始相位错开，开场就不对称
    private let phases: [CGFloat]      = [0.0, 1.2, 2.4, 0.7, 3.1]
    // 各竖条对 RMS 的响应权重（中间高两侧低）
    private let weights: [CGFloat]     = [0.55, 0.80, 1.0, 0.75, 0.50]

    // MARK: - 状态
    private var smoothedRMS: CGFloat = 0
    private var displayTime: CGFloat = 0          // 累计时间（驱动正弦）
    private var barHeights: [CGFloat]
    private var isAnimating = false
    private var timer: Timer?
    private var lastTickDate: Date = Date()

    // MARK: - 平滑系数
    private let attackCoeff: CGFloat  = 0.35      // RMS 上升速度
    private let releaseCoeff: CGFloat = 0.08      // RMS 下降速度（慢）

    // MARK: - 待机呼吸幅度（无声时的最小摆动）
    private let idleAmplitude: CGFloat = 0.06

    override init(frame: NSRect) {
        barHeights = Array(repeating: 3.0, count: 5)
        super.init(frame: frame)
        wantsLayer = true
        startAnimating()
    }

    required init?(coder: NSCoder) {
        barHeights = Array(repeating: 3.0, count: 5)
        super.init(coder: coder)
    }

    deinit { stopAnimating() }

    // MARK: - Public

    func updateRMS(_ rms: Float) {
        let target = CGFloat(rms)
        if target > smoothedRMS {
            smoothedRMS += (target - smoothedRMS) * attackCoeff
        } else {
            smoothedRMS += (target - smoothedRMS) * releaseCoeff
        }
    }

    func stopAnimating() {
        isAnimating = false
        timer?.invalidate()
        timer = nil
        smoothedRMS = 0
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
        // 用 RunLoop 的 common modes 确保拖拽等场景也能更新
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
            // 正弦波（带相位）产生有机摆动
            let sine = sin(displayTime * frequencies[i] + phases[i])  // -1…1

            // 有声时：RMS 驱动振幅 + 竖条权重；无声时：轻微待机呼吸
            let amplitude = smoothedRMS * weights[i] + idleAmplitude
            let normalizedHeight = amplitude * (0.5 + 0.5 * sine)     // 0…amplitude

            let targetHeight = minBarHeight + (maxBarHeight - minBarHeight) * normalizedHeight

            // 每根竖条向目标高度平滑靠近（不直接跳变）
            let coeff: CGFloat = targetHeight > barHeights[i] ? 0.25 : 0.18
            barHeights[i] += (targetHeight - barHeights[i]) * coeff
            barHeights[i] = max(minBarHeight, min(maxBarHeight, barHeights[i]))
        }

        needsDisplay = true
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseColor: NSColor = isDark ? .white : NSColor(white: 0.12, alpha: 1.0)

        for i in 0..<barCount {
            let h = barHeights[i]
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - h) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // 高度越大越不透明，低时略微淡化
            let alpha: CGFloat = 0.55 + 0.45 * ((h - minBarHeight) / (maxBarHeight - minBarHeight))
            ctx.setFillColor(baseColor.withAlphaComponent(alpha).cgColor)
            path.fill()
        }
    }
}
