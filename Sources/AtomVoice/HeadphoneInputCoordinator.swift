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
    private let monitor: HeadphoneMonitor

    init(
        session: RecordingSessionController,
        cancelSherpaAutoUnload: @escaping () -> Void,
        onAccessibilityWarning: @escaping () -> Void
    ) {
        self.session = session
        self.cancelSherpaAutoUnload = cancelSherpaAutoUnload
        self.onAccessibilityWarning = onAccessibilityWarning

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
            }
        )
        monitor.onSingleTap = { [weak self] in self?.handleSingleTap() ?? false }
        monitor.onDoubleTap = { HeadphoneMonitor.sendReturnKey() }
        monitor.onLongPressStart = { [weak self] in self?.handleLongPressStart() }
        monitor.onLongPressEnd = { [weak self] in self?.handleLongPressEnd() }
        monitor.onTapDisabled = { [weak self] in self?.onAccessibilityWarning() }
    }

    // MARK: - 对外 API

    /// 按当前开关启动监听（开关关闭时无副作用）。
    /// (Start monitor if the user has enabled the feature; no-op otherwise.)
    func startIfEnabled() {
        guard AppSettings.headphoneControlEnabled else { return }
        monitor.start()
    }

    /// 由菜单调用：切换开关后启停监听并持久化。
    /// (Called by the menu — toggles persistence + starts/stops the monitor.)
    func setEnabled(_ enabled: Bool) {
        AppSettings.headphoneControlEnabled = enabled
        if enabled {
            monitor.start()
        } else {
            monitor.stop()
        }
    }

    // MARK: - 手势处理

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

    private func toggleRecording() {
        if session.isRecording {
            session.stop()
        } else {
            cancelSherpaAutoUnload()
            session.start()
        }
    }
}
