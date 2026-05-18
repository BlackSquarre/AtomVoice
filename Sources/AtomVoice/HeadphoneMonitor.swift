import Cocoa

/// 监听耳机线控按钮（EarPods/AirPods 上的 play/pause 键），转化为单击 / 双击 / 长按手势。
///
/// 拦截条件：
///   1. AppSettings.headphoneControlEnabled == true
///   2. AudioOutputProbe.isHeadphoneOutputActive() == true
///
/// 手势：
///   - 长按（> 250ms 未松开）：触发 onLongPressStart，松开时触发 onLongPressEnd
///   - 双击（< 280ms 内再次按下并松开）：触发 onDoubleTap
///   - 单击（不是双击的快速点击）：触发 onSingleTap；如果回调返回 false，则把原 play/pause 事件
///     补发给系统，让音乐照常播放/暂停
final class HeadphoneMonitor {
    var onSingleTap: () -> Bool        // 返回 true 表示已处理，无需补发 play/pause
    var onDoubleTap: () -> Void
    var onLongPressStart: () -> Void
    var onLongPressEnd: () -> Void
    var onTapDisabled: (() -> Void)?
    /// 一些 USB DAC（如 MOONDROP MAY）的双击中键不发标准 play/pause，
    /// 而是直接发"辅助鼠标按钮"事件（NX_SUBTYPE_AUX_MOUSE_BUTTONS, data1=1）。
    /// 回调返回 true 表示已处理（吞掉原事件，避免触发系统全屏手势）。
    /// (Some USB DACs fire NX_SUBTYPE_AUX_MOUSE_BUTTONS for the middle-button double-click
    ///  instead of two play/pause events. Return true to consume the event.)
    var onAuxMouseButton: () -> Bool = { false }

    /// 由外部根据「开关 + 当前输出设备」综合决定是否拦截
    var isInterceptEnabled: () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - 手势状态

    private enum State {
        case idle
        case pressed                 // 按下未达到长按阈值
        case longPressActive         // 长按已触发，等待松开
        case awaitingSecondTap       // 第一次快速点击完成，等待 280ms 看是否双击
    }
    private var state: State = .idle
    private var longPressTimer: Timer?
    private var doubleTapTimer: Timer?
    private var pendingPlayPauseEvent: CGEvent?  // 等待是否补发的原始事件副本
    private var isSecondPress = false            // 当前 .pressed 是否来自双击的第二次按下

    private static let longPressThreshold: TimeInterval = 0.25
    private static let doubleTapWindow: TimeInterval = 0.28

    // MARK: - 媒体键常量

    private static let nxSysDefinedType: UInt32 = 14
    private static let nxSubtypeAuxControlButtons: Int16 = 8
    private static let nxSubtypeAuxMouseButtons: Int16 = 7   // NX_SUBTYPE_AUX_MOUSE_BUTTONS
    private static let nxKeyTypePlay: Int32 = 16   // NX_KEYTYPE_PLAY

    // MARK: - 生命周期

    init(
        onSingleTap: @escaping () -> Bool,
        onDoubleTap: @escaping () -> Void,
        onLongPressStart: @escaping () -> Void,
        onLongPressEnd: @escaping () -> Void,
        isInterceptEnabled: @escaping () -> Bool
    ) {
        self.onSingleTap = onSingleTap
        self.onDoubleTap = onDoubleTap
        self.onLongPressStart = onLongPressStart
        self.onLongPressEnd = onLongPressEnd
        self.isInterceptEnabled = isInterceptEnabled
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << HeadphoneMonitor.nxSysDefinedType)
        // .cghidEventTap：HID 层最早的位置；session 层返回 nil 拦不住 WindowServer
        // 把 aux mouse 解释成全屏/Mission Control 的系统手势。
        // (Hook at the HID layer so returning nil actually blocks WindowServer's gesture handling.)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HeadphoneMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.error("[HeadphoneMonitor] 无法创建事件监听（缺少辅助功能权限？）")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.info("[HeadphoneMonitor] 已启动")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetGesture()
        DebugLog.info("[HeadphoneMonitor] 已停止")
    }

    // MARK: - 事件处理

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    DispatchQueue.main.async { [weak self] in self?.onTapDisabled?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == HeadphoneMonitor.nxSysDefinedType else {
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)

        // 辅助鼠标按钮事件：仅当业务方在窗口期内处理（如录音中）时才吞掉，避免误伤普通鼠标侧键
        // (Aux-mouse-button events: only swallow when the callback consumes them within an active window.)
        if nsEvent.subtype.rawValue == HeadphoneMonitor.nxSubtypeAuxMouseButtons && data1 == 1 {
            guard isInterceptEnabled() else {
                return Unmanaged.passUnretained(event)
            }
            // 事件 tap 已挂在 main runloop 上，回调直接同步执行
            // (The tap is wired to the main runloop, so the callback runs synchronously here.)
            let handled = onAuxMouseButton()
            return handled ? nil : Unmanaged.passUnretained(event)
        }

        // 只处理 AUX 控制按钮中的 PLAY 键
        guard nsEvent.subtype.rawValue == HeadphoneMonitor.nxSubtypeAuxControlButtons else {
            return Unmanaged.passUnretained(event)
        }
        guard keyCode == HeadphoneMonitor.nxKeyTypePlay else {
            return Unmanaged.passUnretained(event)
        }

        // 综合开关 + 当前输出设备判断
        guard isInterceptEnabled() else {
            return Unmanaged.passUnretained(event)
        }

        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A    // NX_KEYDOWN

        // 拷贝事件以便后续可能补发（必须在返回 nil 之前）
        let copy = event.copy()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isKeyDown {
                self.handlePlayKeyDown(originalCopy: copy)
            } else {
                self.handlePlayKeyUp()
            }
        }
        return nil   // 吞掉原事件
    }

    private func handlePlayKeyDown(originalCopy: CGEvent?) {
        switch state {
        case .idle:
            pendingPlayPauseEvent = originalCopy
            isSecondPress = false
            state = .pressed
            scheduleLongPressTimer()
        case .awaitingSecondTap:
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
            pendingPlayPauseEvent = nil
            isSecondPress = true
            state = .pressed
            scheduleLongPressTimer()
        case .pressed, .longPressActive:
            break
        }
    }

    private func handlePlayKeyUp() {
        longPressTimer?.invalidate()
        longPressTimer = nil

        switch state {
        case .longPressActive:
            state = .idle
            isSecondPress = false
            pendingPlayPauseEvent = nil
            onLongPressEnd()
        case .pressed:
            if isSecondPress {
                state = .idle
                isSecondPress = false
                onDoubleTap()
            } else {
                state = .awaitingSecondTap
                scheduleDoubleTapTimer()
            }
        default:
            break
        }
    }

    private func scheduleLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: HeadphoneMonitor.longPressThreshold, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.state == .pressed else { return }
            self.state = .longPressActive
            self.pendingPlayPauseEvent = nil   // 长按已确认，不再补发 play/pause
            self.onLongPressStart()
        }
    }

    private func scheduleDoubleTapTimer() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = Timer.scheduledTimer(withTimeInterval: HeadphoneMonitor.doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.state == .awaitingSecondTap else { return }
            // 单击落定
            let cachedEvent = self.pendingPlayPauseEvent
            self.pendingPlayPauseEvent = nil
            self.state = .idle
            let handled = self.onSingleTap()
            if !handled, let event = cachedEvent {
                // 单击未被业务消化 → 把 play/pause 还给系统，让音乐照常控制
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// 合成回车键发送给当前前台 App（用于双击 → Enter）
    /// 关键：使用 .privateState 不带继承的修饰键，并显式清空 flags，
    /// 否则若系统当前以为有 Cmd/Ctrl/Shift 被按住，Return 会变成 Cmd+W / Cmd+Shift+T / Cmd+Ctrl+F 等组合键。
    /// (Use .privateState and explicitly clear flags, otherwise inherited modifiers turn Return into Cmd+W etc.)
    static func sendReturnKey() {
        let source = CGEventSource(stateID: .privateState)
        let returnKeyCode: CGKeyCode = 0x24  // Return
        let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func resetGesture() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        pendingPlayPauseEvent = nil
        isSecondPress = false
        state = .idle
    }
}
