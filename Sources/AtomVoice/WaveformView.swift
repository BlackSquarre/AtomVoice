import Cocoa

final class WaveformView: NSView {
    // MARK: - Layout
    private let barCount = 5
    private let barWidth: CGFloat  = 3.0   // 5根 × 3 + 4间距 × 2 = 23pt，居中在28pt容器内
    private let barSpacing: CGFloat = 2.0
    private let minBarHeight: CGFloat = 3.0
    private let maxBarHeight: CGFloat = 26.0

    // MARK: - 正弦波参数
    // 低频竖条（左）振荡慢，高频竖条（右）振荡快，与音频频段特性一致
    private let oscFreqs: [CGFloat]  = [1.4, 2.2, 3.1, 4.6, 6.3]   // rad/s，从慢到快
    private let initPhases: [CGFloat] = [0.0, 1.1, 2.3, 0.5, 3.0]  // 初始相位错开

    // MARK: - 状态
    private var bandLevels: [CGFloat] = [0, 0, 0, 0, 0]   // 来自 FFT 的 5 个频段能量
    private var smoothedLevels: [CGFloat] = [0, 0, 0, 0, 0]
    private var barHeights: [CGFloat]
    private var displayTime: CGFloat = 0
    private var isAnimating = false
    private var timer: Timer?
    private var lastTickDate: Date = Date()

    // MARK: - 响应速度
    // attack 快（说话时立刻响应），release 慢（有余韵感）
    private let attackCoeff:  CGFloat = 0.80   // 快速上升
    private let releaseCoeff: CGFloat = 0.12   // 缓慢下降

    // 待机呼吸幅度（无声时轻微摆动）
    private let idleAmplitude: CGFloat = 0.05

    // MARK: - Init

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

    /// 接收来自 AudioEngine FFT 的 5 频段能量（0-1）
    func updateBands(_ bands: [Float]) {
        for i in 0..<min(bands.count, barCount) {
            let target = CGFloat(bands[i])
            let current = bandLevels[i]
            if target > current {
                bandLevels[i] += (target - current) * attackCoeff
            } else {
                bandLevels[i] += (target - current) * releaseCoeff
            }
        }
    }

    /// 兼容旧的 RMS 接口（全频段同等驱动）
    func updateRMS(_ rms: Float) {
        let level = CGFloat(rms)
        for i in 0..<barCount {
            let current = bandLevels[i]
            if level > current {
                bandLevels[i] += (level - current) * attackCoeff
            } else {
                bandLevels[i] += (level - current) * releaseCoeff
            }
        }
    }

    func stopAnimating() {
        isAnimating = false
        timer?.invalidate()
        timer = nil
        bandLevels     = [0, 0, 0, 0, 0]
        smoothedLevels = [0, 0, 0, 0, 0]
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
            // 正弦波产生有机摆动
            let sine = sin(displayTime * oscFreqs[i] + initPhases[i])  // -1…1
            let level = bandLevels[i]

            // 振幅 = 实际频段能量 + 待机呼吸
            // 高度 = 基础 + 振幅 * (0.5 + 0.5*sine) 使高度始终 ≥ 基础
            let amplitude = level + idleAmplitude
            let normalized = amplitude * (0.5 + 0.5 * sine)
            let targetHeight = minBarHeight + (maxBarHeight - minBarHeight) * normalized

            // 竖条高度平滑追踪目标
            let coeff: CGFloat = targetHeight > barHeights[i] ? 0.30 : 0.20
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

        // labelColor 自动适配深浅色及玻璃/毛玻璃背景
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
