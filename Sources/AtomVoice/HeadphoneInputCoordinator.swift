import Foundation

/// 把耳机线控按钮事件协调到 RecordingSessionController。
///
/// 职责：
///   - 拥有 HeadphoneMonitor 的生命周期
///   - 按当前输入模式（单击说话 / 长按说话）把单击、长按映射成 session.start / stop / toggle
///   - 双击恒定发送回车
///   - 通过 `isInterceptEnabled` 把 "开关 + 输出设备" 的条件聚合给 monitor
final class HeadphoneInputCoordinator {
    private let session: RecordingSessionController
    private let cancelSherpaAutoUnload: () -> Void
    private let onAccessibilityWarning: () -> Void
    private let hidSourceMonitor: HeadphoneHIDSourceMonitor
    private let monitor: HeadphoneMonitor

    // 部分 USB DAC 的双击会发 NX_SUBTYPE_AUX_MOUSE_BUTTONS（而非两次 play/pause）。
    // 为避免误伤普通鼠标侧键，只在录音中 / 刚结束录音的窗口内把这种事件当作"双击 → 回车"。
    // (Some USB DACs emit aux-mouse-button events for the double-click. To avoid hijacking real
    //  mouse aux clicks we only treat them as "double-tap → Return" while recording, or shortly after.)
    private var lastRecordingEndTime: Date = .distantPast
    private var lastAuxEmitTime: Date = .distantPast
    private var optimisticRecordingStarted = false
    private static let auxWindowAfterStop: TimeInterval = 60.0
    private static let auxDebounce: TimeInterval = 0.3
    private static let hidSourceWindow: TimeInterval = 0.15

    init(
        session: RecordingSessionController,
        cancelSherpaAutoUnload: @escaping () -> Void,
        onAccessibilityWarning: @escaping () -> Void
    ) {
        self.session = session
        self.cancelSherpaAutoUnload = cancelSherpaAutoUnload
        self.onAccessibilityWarning = onAccessibilityWarning
        let sourceMonitor = HeadphoneHIDSourceMonitor()
        self.hidSourceMonitor = sourceMonitor

        // monitor 先构造空回调，再在下面绑定 self；这样 monitor 是 let 但能引用 coordinator
        let placeholderSingle: () -> Bool = { false }
        let placeholderVoid: () -> Void = {}
        self.monitor = HeadphoneMonitor(
            onSingleTap: placeholderSingle,
            onDoubleTap: placeholderVoid,
            onLongPressStart: placeholderVoid,
            onLongPressEnd: placeholderVoid,
            isInterceptEnabled: {
                AppSettings.headphoneControlEnabled && AudioOutputProbe.isHeadphoneOutputActive()
            },
            hasTrustedPlayPauseSource: {
                sourceMonitor.hasRecentTrustedPlayPauseEvent(within: HeadphoneInputCoordinator.hidSourceWindow)
            }
        )
        monitor.onSingleTap = { [weak self] in self?.handleSingleTap() ?? false }
        monitor.onOptimisticSingleTap = { [weak self] in self?.handleOptimisticSingleTap() ?? false }
        monitor.onCancelOptimisticSingleTap = { [weak self] in self?.cancelOptimisticSingleTap() }
        monitor.onOptimisticSingleTapSettled = { [weak self] in self?.settleOptimisticSingleTap() }
        monitor.onDoubleTap = { HeadphoneMonitor.sendReturnKey() }
        monitor.onLongPressStart = { [weak self] in self?.handleLongPressStart() }
        monitor.onLongPressEnd = { [weak self] in self?.handleLongPressEnd() }
        monitor.onTapDisabled = { [weak self] in self?.onAccessibilityWarning() }
        monitor.onAuxMouseButton = { [weak self] in self?.handleAuxMouseButton() ?? false }
    }

    /// 由 session 状态回调通知：录音状态变化（active=true 进入录音；false 结束）。
    /// (Session state callback — used to gate aux-mouse-button hijacking.)
    func notifyRecordingStateChanged(_ active: Bool) {
        if !active {
            lastRecordingEndTime = Date()
            optimisticRecordingStarted = false
        }
    }

    // MARK: - 对外 API

    /// 按当前开关启动监听（开关关闭时无副作用）。
    /// (Start monitor if the user has enabled the feature; no-op otherwise.)
    func startIfEnabled() {
        guard AppSettings.headphoneControlEnabled else { return }
        hidSourceMonitor.start()
        monitor.start()
    }

    /// 由菜单调用：切换开关后启停监听并持久化。
    /// (Called by the menu — toggles persistence + starts/stops the monitor.)
    func setEnabled(_ enabled: Bool) {
        AppSettings.headphoneControlEnabled = enabled
        if enabled {
            hidSourceMonitor.start()
            monitor.start()
        } else {
            monitor.stop()
            hidSourceMonitor.stop()
        }
    }

    // MARK: - 手势处理

    private func handleOptimisticSingleTap() -> Bool {
        if session.isShowingError {
            session.dismissError()
            return true
        }
        guard AppSettings.silenceAutoStopEnabled else { return false }
        guard !session.isRecordingOrStarting else { return false }
        cancelSherpaAutoUnload()
        optimisticRecordingStarted = true
        session.startDeferringCapsulePresentation()
        return true
    }

    private func cancelOptimisticSingleTap() {
        guard optimisticRecordingStarted else { return }
        optimisticRecordingStarted = false
        session.cancel()
    }

    private func settleOptimisticSingleTap() {
        guard optimisticRecordingStarted else { return }
        optimisticRecordingStarted = false
        session.revealDeferredCapsulePresentation()
    }

    private func handleSingleTap() -> Bool {
        if session.isShowingError {
            session.dismissError()
            return true
        }
        if AppSettings.silenceAutoStopEnabled {
            // 单击说话模式：toggle 录音
            toggleRecording()
            return true
        }
        // 长按说话模式下单击未消费，让 play/pause 回到系统控制音乐
        return false
    }

    private func handleLongPressStart() {
        if session.isShowingError {
            session.dismissError()
            return
        }
        if AppSettings.silenceAutoStopEnabled {
            // 单击模式下长按也走 toggle，避免"按下没反应"
            toggleRecording()
        } else {
            cancelSherpaAutoUnload()
            session.start()
        }
    }

    private func handleLongPressEnd() {
        guard !AppSettings.silenceAutoStopEnabled else { return }
        session.stop()
    }

    /// 在"录音中 / 刚结束录音 5s 内"才把辅助鼠标按钮事件当作"双击 → 回车"，
    /// 并做 300ms 去抖（一次双击会发出 2 个事件，间隔仅几毫秒）。
    /// (Hijack aux-mouse-button only while/just after recording. Debounce to one Return per double-click.)
    private func handleAuxMouseButton() -> Bool {
        let now = Date()
        let inWindow = session.isRecordingOrStarting ||
            now.timeIntervalSince(lastRecordingEndTime) < HeadphoneInputCoordinator.auxWindowAfterStop
        guard inWindow else { return false }
        if now.timeIntervalSince(lastAuxEmitTime) < HeadphoneInputCoordinator.auxDebounce {
            return true  // 吞掉同一双击的伴随事件
        }
        lastAuxEmitTime = now
        HeadphoneMonitor.sendReturnKey()
        return true
    }

    private func toggleRecording() {
        if session.isRecordingOrStarting {
            session.stop()
        } else {
            cancelSherpaAutoUnload()
            session.start()
        }
    }
}
