import Foundation

/// ASR 静音监控：基于"识别文本是否还在增长"判断是否停止说话。
/// 不再依赖音频能量 VAD —— 噪声环境下能量域信号会被淹没，但只要 ASR 还在输出新文本，就视为还在说话。
///
/// 使用流程：
/// - 录音开始时 `start()`
/// - 每次收到 partial/final 文本调 `noteText(_:)`
/// - 内部 timer 周期性检查：距上次"文本变化"已超过 `AppSettings.silenceDuration` → 触发 `onTimeout`
/// - 录音结束（或外部主动停）时 `stop()`
final class ASRSilenceMonitor {
    var onTimeout: (() -> Void)?

    /// 录音开始后多久内不做静音判定，避免开局还没出文本就立刻误停
    /// (Guard window from recording start; no timeout fires before this elapses.)
    private let guardPeriod: TimeInterval = 0.5
    private let tickInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.atomvoice.asrSilenceMonitor")
    private var timer: DispatchSourceTimer?
    private var startedAt: Date?
    private var lastChangeAt: Date?
    private var lastText: String = ""
    private var didFire = false

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.startedAt = now
            self.lastChangeAt = now
            self.lastText = ""
            self.didFire = false

            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.tickInterval, repeating: self.tickInterval)
            t.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.startedAt = nil
            self.lastChangeAt = nil
            self.lastText = ""
            self.didFire = false
        }
    }

    /// 收到新的 partial / final 识别文本。
    /// text 与上次不一致就视为"心跳"，刷新 lastChangeAt。
    func noteText(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if text != self.lastText {
                self.lastText = text
                self.lastChangeAt = Date()
            }
        }
    }

    private func tick() {
        guard !didFire else { return }
        guard AppSettings.silenceAutoStopEnabled else { return }
        guard !AppSettings.tapModeManualStop else { return }
        guard let startedAt, let lastChangeAt else { return }

        let now = Date()
        guard now.timeIntervalSince(startedAt) > guardPeriod else { return }

        let silenceElapsed = now.timeIntervalSince(lastChangeAt)
        let required = AppSettings.silenceDuration
        guard silenceElapsed >= required else { return }

        didFire = true
        let callback = onTimeout
        DispatchQueue.main.async {
            callback?()
        }
    }
}
