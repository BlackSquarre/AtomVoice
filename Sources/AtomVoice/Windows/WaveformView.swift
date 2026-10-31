import Cocoa

/// 波形只在绘制节拍平滑一次；真实时间常数不随音频回调频率或显示帧率漂移。
struct WaveformEnvelope {
    static let bandCount = 5
    private var targets = [Double](repeating: 0, count: WaveformEnvelope.bandCount)
    private(set) var levels = [Double](repeating: 0, count: WaveformEnvelope.bandCount)

    mutating func updateBands(_ bands: [Float]) {
        for index in targets.indices {
            let value = index < bands.count ? Double(bands[index]) : 0
            targets[index] = value.isFinite && value >= 0.008 ? min(1, value) : 0
        }
    }

    mutating func advance(by elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let attack = 1 - exp(-elapsed / 0.028)
        let release = 1 - exp(-elapsed / 0.110)
        for index in levels.indices {
            let coefficient = targets[index] > levels[index] ? attack : release
            levels[index] += (targets[index] - levels[index]) * coefficient
        }
    }

    mutating func reset() {
        targets = [Double](repeating: 0, count: Self.bandCount)
        levels = targets
    }
}

final class WaveformView: NSView {
    // MARK: - Layout
    private let barCount = WaveformEnvelope.bandCount
    private let barWidth: CGFloat  = 3.0   // 5根 × 3 + 4间距 × 2 = 23pt，居中在28pt容器内（5 bars × 3 + 4 gaps × 2 = 23pt, centered in 28pt container）
    private let barSpacing: CGFloat = 2.0
    private let minBarHeight: CGFloat = 3.0
    private let maxBarHeight: CGFloat = 26.0

    // MARK: - 正弦波参数
    // 仅提供缓慢微动，不再让高频细节造成碎跳。（Provides only slow micro-motion, no more high-freq detail causing jitter.）
    private let oscFreqs: [CGFloat]  = [2.8, 3.4, 3.9, 3.2, 2.6]
    private let initPhases: [CGFloat] = [0.0, 2.1, 0.8, 2.9, 1.4]

    // MARK: - 状态
    private var envelope = WaveformEnvelope()
    private var barHeights: [CGFloat]
    private var displayTime: CGFloat = 0
    private var isAnimating = false
    private var timer: Timer?
    private var lastTickUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

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
        envelope.updateBands(bands)
    }

    /// 兼容旧的 RMS 接口（全频段同等驱动）（Compatible with legacy RMS interface (all bands driven equally)）
    func updateRMS(_ rms: Float) {
        updateBands(Array(repeating: rms, count: barCount))
    }

    func stopAnimating() {
        isAnimating = false
        timer?.invalidate()
        timer = nil
        envelope.reset()
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
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isAnimating else { return }
            self.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTickUptime
        lastTickUptime = now
        displayTime += CGFloat(dt)
        envelope.advance(by: dt)

        for i in 0..<barCount {
            // 正弦波只做轻微调制，真实音量决定主体高度。（Sine wave only provides subtle modulation; real volume determines bar height.）
            let sine = sin(displayTime * oscFreqs[i] + initPhases[i])  // -1…1
            let level = CGFloat(envelope.levels[i])

            let pulse = 0.97 + 0.03 * sine
            let quietness = max(0, 1 - level * 5)
            let idle = idleAmplitude * quietness * (0.5 + 0.5 * sine)
            let normalized = min(1, level * pulse + idle)
            let targetHeight = minBarHeight + (maxBarHeight - minBarHeight) * normalized

            // envelope 已完成平滑，高度不再叠加第二层阻尼。
            barHeights[i] = max(minBarHeight, min(maxBarHeight, targetHeight))
        }

        needsDisplay = true
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
