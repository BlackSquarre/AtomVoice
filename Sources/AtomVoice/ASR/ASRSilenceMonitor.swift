import Foundation

/// 自动停录监控：有效文字进展和持续的声音证据都可续录，最终停止仍使用用户选择的静默时长。
/// 声音证据复用现有音频分析，不裁剪送给识别器的音频，也不阻塞开始收音。
final class ASRSilenceMonitor {
    struct Settings {
        var enabled: Bool
        var manualStop: Bool
        var duration: TimeInterval
    }

    typealias TickScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    var onTimeout: (() -> Void)?

    private let guardPeriod: TimeInterval = 0.5
    private let tickInterval: TimeInterval = 0.1
    private let minimumVoiceRun: TimeInterval = 0.064
    private let maximumVoiceGap: TimeInterval = 0.12
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let settings: () -> Settings
    private let scheduleTick: TickScheduler
    private let enqueueTimeout: (@escaping () -> Void) -> Void
    private var cancelTimer: (() -> Void)?
    private var generation = 0
    private var activityRevision = 0
    private var startedAt: TimeInterval?
    private var lastActivityAt: TimeInterval?
    private var graceUntil: TimeInterval?
    private var maximumTextCount = 0
    private var lastText = ""
    private var recentMeaningfulTexts: [String] = []
    private var voiceRunStartedAt: TimeInterval?
    private var lastAudioObservationAt: TimeInterval?
    private var voiceConfirmationDeadline: TimeInterval?
    private var timeoutPending = false
    private var didFire = false

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        settings: @escaping () -> Settings = {
            Settings(enabled: AppSettings.silenceAutoStopEnabled,
                     manualStop: AppSettings.tapModeManualStop,
                     duration: AppSettings.silenceDuration)
        },
        scheduleTick: TickScheduler? = nil,
        enqueueTimeout: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.now = now
        self.settings = settings
        self.scheduleTick = scheduleTick ?? Self.scheduleRepeatingTick
        self.enqueueTimeout = enqueueTimeout
    }

    deinit { cancelTimer?() }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        cancelTimer?()
        generation += 1
        activityRevision = 0
        let token = generation
        let timestamp = now()
        startedAt = timestamp
        lastActivityAt = timestamp
        graceUntil = nil
        maximumTextCount = 0
        lastText = ""
        recentMeaningfulTexts.removeAll(keepingCapacity: true)
        voiceRunStartedAt = nil
        lastAudioObservationAt = nil
        voiceConfirmationDeadline = nil
        timeoutPending = false
        didFire = false
        cancelTimer = scheduleTick(tickInterval) { [weak self] in self?.tick(generation: token) }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        // 立即使已经排到主线程的旧停止提案失效，不能让它结束下一轮录音。
        generation += 1
        cancelTimer?()
        cancelTimer = nil
        startedAt = nil
        lastActivityAt = nil
        graceUntil = nil
        maximumTextCount = 0
        lastText = ""
        recentMeaningfulTexts.removeAll(keepingCapacity: true)
        voiceRunStartedAt = nil
        lastAudioObservationAt = nil
        voiceConfirmationDeadline = nil
        timeoutPending = false
        didFire = false
    }

    /// 保留识别路径切换时的宽限期，例如豆包回退 Apple 后等待首个 partial。
    func extendTimeout(by duration: TimeInterval) {
        guard duration > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard startedAt != nil, !didFire else { return }
        let candidate = now() + duration
        if let graceUntil, graceUntil >= candidate { return }
        graceUntil = candidate
        activityRevision += 1
    }

    /// 有效文字增长或同长度的新修订都构成心跳，不要求始终保持相同前缀。
    /// 长度高水位和有界历史排除截短、往返回退、标点修订与完全重复。
    func noteText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard startedAt != nil, !didFire, text != lastText else { return }
        lastText = text
        let meaningful = Self.meaningfulText(text)
        let count = meaningful.count
        guard count > 0, count >= maximumTextCount, !recentMeaningfulTexts.contains(meaningful) else { return }
        maximumTextCount = count
        recentMeaningfulTexts.append(meaningful)
        if recentMeaningfulTexts.count > 16 { recentMeaningfulTexts.removeFirst() }
        noteActivityLocked(at: now())
    }

    /// 每个现有 FFT 分析帧都要传 true/false，不能只传 true，否则短促声音无法正确断开。
    /// 时间戳取自音频采集的单调时间，而不是延迟处理或主线程回调时刻。
    func noteVoiceActivity(isVoiceLike: Bool, at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt, !didFire, timestamp >= startedAt, timestamp <= now() else { return }
        if let previous = lastAudioObservationAt {
            guard timestamp >= previous else { return }
            if timestamp == previous {
                // 同一采集 buffer 可能产生多个 FFT 窗口；不能重复计时，但安静窗口仍须断开连续段。
                if !isVoiceLike { voiceRunStartedAt = nil }
                return
            }
        }
        let gap = lastAudioObservationAt.map { timestamp - $0 }
        lastAudioObservationAt = timestamp
        guard isVoiceLike else {
            voiceRunStartedAt = nil
            return
        }
        if voiceRunStartedAt == nil || (gap ?? .infinity) > maximumVoiceGap {
            voiceRunStartedAt = timestamp
        }
        guard let onset = voiceRunStartedAt, timestamp - onset + 1e-9 >= minimumVoiceRun else { return }
        noteActivityLocked(at: timestamp)
    }

    private func noteActivityLocked(at timestamp: TimeInterval) {
        guard timestamp > (lastActivityAt ?? timestamp) else { return }
        lastActivityAt = timestamp
        voiceConfirmationDeadline = nil
        activityRevision += 1
    }

    private static func meaningfulText(_ text: String) -> String {
        let kept = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let scalars = text.unicodeScalars.filter { kept.contains($0) }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping.lowercased()
    }

    private func shouldTimeoutLocked() -> Bool {
        let configuration = settings()
        guard configuration.enabled, !configuration.manualStop,
              let startedAt, let lastActivityAt else { return false }
        let timestamp = now()
        guard timestamp - startedAt > guardPeriod else { return false }
        guard timestamp - lastActivityAt >= configuration.duration else { return false }
        if let onset = voiceRunStartedAt, let observation = lastAudioObservationAt,
           observation - onset < minimumVoiceRun, timestamp - observation <= maximumVoiceGap {
            // 到期前刚开始发声时给短暂确认机会；同一静默周期只设一次截止，稀疏脉冲不能无限续期。
            if voiceConfirmationDeadline == nil { voiceConfirmationDeadline = onset + maximumVoiceGap }
            if let deadline = voiceConfirmationDeadline, timestamp < deadline { return false }
        }
        if let graceUntil, timestamp < graceUntil { return false }
        return true
    }

    private func tick(generation token: Int) {
        lock.lock()
        guard generation == token, !didFire, !timeoutPending, shouldTimeoutLocked() else {
            lock.unlock()
            return
        }
        timeoutPending = true
        let revision = activityRevision
        lock.unlock()
        enqueueTimeout { [weak self] in self?.deliverTimeout(generation: token, revision: revision) }
    }

    private func deliverTimeout(generation token: Int, revision: Int) {
        lock.lock()
        guard generation == token else {
            lock.unlock()
            return
        }
        timeoutPending = false
        // 主线程排队期间的声音、文字、宽限期与设置变化都必须重新核对。
        guard !didFire, activityRevision == revision, shouldTimeoutLocked() else {
            lock.unlock()
            return
        }
        didFire = true
        let callback = onTimeout
        lock.unlock()
        callback?()
    }

    private static func scheduleRepeatingTick(interval: TimeInterval, action: @escaping () -> Void) -> () -> Void {
        let queue = DispatchQueue(label: "com.atomvoice.asrSilenceMonitor")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: action)
        timer.resume()
        return { timer.cancel() }
    }
}
