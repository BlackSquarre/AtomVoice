import Cocoa

// MARK: - 触发键配置

struct TriggerKeyOption {
    let keyCode: UInt16
    let locKey: String          // 用于本地化菜单标题（Localization key for menu title）
    let flagMask: CGEventFlags  // 对应的修饰键 flag（Corresponding modifier key flag）
    let symbolKey: String       // 本地化 key，用于顶部提示文字（Localization key for top prompt text）

    static let all: [TriggerKeyOption] = [
        TriggerKeyOption(keyCode: 63, locKey: "menu.triggerKey.fn",           flagMask: .maskSecondaryFn, symbolKey: "menu.triggerKey.fn.symbol"),
        TriggerKeyOption(keyCode: 59, locKey: "menu.triggerKey.leftControl",  flagMask: .maskControl,     symbolKey: "menu.triggerKey.leftControl.symbol"),
        TriggerKeyOption(keyCode: 58, locKey: "menu.triggerKey.leftOption",   flagMask: .maskAlternate,   symbolKey: "menu.triggerKey.leftOption.symbol"),
        TriggerKeyOption(keyCode: 54, locKey: "menu.triggerKey.rightCommand", flagMask: .maskCommand,     symbolKey: "menu.triggerKey.rightCommand.symbol"),
        TriggerKeyOption(keyCode: 61, locKey: "menu.triggerKey.rightOption",  flagMask: .maskAlternate,   symbolKey: "menu.triggerKey.rightOption.symbol"),
        TriggerKeyOption(keyCode: 62, locKey: "menu.triggerKey.rightControl", flagMask: .maskControl,     symbolKey: "menu.triggerKey.rightControl.symbol"),
    ]

    static func option(for keyCode: UInt16) -> TriggerKeyOption {
        all.first { $0.keyCode == keyCode } ?? all[0]
    }
}

// MARK: - FnKeyMonitor

final class FnKeyMonitor {
    private let onFnDown: () -> Void
    private let onFnUp: () -> Void
    var onTapDisabled: (() -> Void)?  // 权限丢失时通知外部（Notify external when accessibility permission is lost）

    // 录音期间的按键回调（Key callbacks during recording）
    var onEscPressed: (() -> Void)?         // ESC 取消录音（ESC cancels recording）
    var onCommitStop: (() -> Void)?         // Return 确认结束，保留 LLM 优化（Return commits recording, keeping LLM refinement）
    var onImmediateStop: ((String?) -> Void)?  // Space/Backspace/标点立即上屏（Space/Backspace/punctuation injects immediately）
    var isRecording = false                  // 由 AppDelegate 设置（Set by AppDelegate）
    var isRefining = false                   // 由 AppDelegate 设置（Set by AppDelegate）

    // 当前触发键，可运行时修改，修改后自动重置按下状态（Current trigger key, can be changed at runtime, auto-resets pressed state on change）
    var triggerKeyCode: UInt16 = 61 {
        didSet { triggerIsDown = false }
    }

    private var triggerIsDown = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let fnKeyCode: UInt16 = 0x3F  // 63
    private static let escKeyCode: UInt16 = 0x35  // 53
    private static let returnKeyCode: UInt16 = 0x24  // 36
    private static let spaceKeyCode: UInt16 = 0x31  // 49
    private static let backspaceKeyCode: UInt16 = 0x33  // 51

    init(onFnDown: @escaping () -> Void, onFnUp: @escaping () -> Void) {
        self.onFnDown = onFnDown
        self.onFnUp = onFnUp
    }

    func start() {
        // 已启动则跳过，避免重复创建 tap（Idempotent: skip if already running, avoid duplicate taps）
        guard eventTap == nil else { return }

        // 监听按键 + 修饰键 + 系统定义事件（NX_SYSDEFINED = 14，Globe 键行为通过此事件触发）
        // (Listen for key events + modifier flags + system-defined events; NX_SYSDEFINED = 14 is how the Globe key behaves)
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << 14)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else {
            DebugLog.error("[FnKeyMonitor] 无法创建事件监听。请在系统设置 > 隐私与安全性 > 辅助功能中授权本应用。")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.info("[FnKeyMonitor] 事件监听已启动")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // 释放 start() 中 passRetained 的强引用（Release the retained reference from start()）
            Unmanaged<FnKeyMonitor>.passUnretained(self).release()
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DebugLog.info("[FnKeyMonitor] 事件 tap 被系统禁用，正在重启...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onTapDisabled?()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // NX_SYSDEFINED（type 14）：仅在使用 Fn/Globe 作为触发键时才需要拦截系统字符检视器事件
        // (NX_SYSDEFINED (type 14): only intercept system character viewer events when using Fn/Globe as trigger key)
        if type.rawValue == 14 {
            guard triggerKeyCode == FnKeyMonitor.fnKeyCode else {
                return Unmanaged.passUnretained(event)
            }
            if let nsEvent = NSEvent(cgEvent: event) {
                let subtype = nsEvent.subtype.rawValue
                let data1 = nsEvent.data1
                let keyCode = (data1 & 0xFFFF0000) >> 16
                DebugLog.info("[FnKeyMonitor] NX_SYSDEFINED subtype=\(subtype) data1=\(data1) keyCode=\(keyCode) flags=\(event.flags.rawValue)")
                if subtype == 211 {
                    DebugLog.info("[FnKeyMonitor] 拦截 NX_SYSDEFINED subtype=211 (系统辅助控制)")
                    return nil
                }
            }
            if event.flags.contains(.maskSecondaryFn) {
                DebugLog.info("[FnKeyMonitor] 拦截 NX_SYSDEFINED (Fn flag 检测)")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            // Fn 专属路径：某些键盘上 Fn/Globe 键会产生真实的 keyDown/keyUp
            // (Fn-specific path: on some keyboards, the Fn/Globe key generates real keyDown/keyUp events)
            if triggerKeyCode == FnKeyMonitor.fnKeyCode && keyCode == FnKeyMonitor.fnKeyCode {
                if type == .keyDown && !triggerIsDown {
                    triggerIsDown = true
                    DebugLog.info("[FnKeyMonitor] >>> 触发键按下 (keyDown keyCode=63)")
                    onFnDown()
                } else if type == .keyUp && triggerIsDown {
                    triggerIsDown = false
                    DebugLog.info("[FnKeyMonitor] >>> 触发键松开 (keyUp keyCode=63)")
                    onFnUp()
                }
                return nil
            }

            // 录音或润色期间拦截特殊按键（仅 keyDown）（Intercept special keys during recording or refining, keyDown only）
            if type == .keyDown {
                if isRecording {
                    switch keyCode {
                    case FnKeyMonitor.escKeyCode:
                        DebugLog.info("[FnKeyMonitor] >>> ESC 取消录音")
                        DispatchQueue.main.async { [weak self] in
                            self?.onEscPressed?()
                        }
                        return nil

                    case FnKeyMonitor.returnKeyCode:
                        DebugLog.info("[FnKeyMonitor] >>> Return 确认结束录音")
                        DispatchQueue.main.async { [weak self] in
                            self?.onCommitStop?()
                        }
                        return nil

                    case FnKeyMonitor.spaceKeyCode, FnKeyMonitor.backspaceKeyCode:
                        DebugLog.info("[FnKeyMonitor] >>> Space/Backspace 立即上屏")
                        DispatchQueue.main.async { [weak self] in
                            self?.onImmediateStop?(nil)
                        }
                        return nil

                    default:
                        if let punctuation = typedPunctuation(from: event) {
                            DebugLog.info("[FnKeyMonitor] >>> 标点立即上屏: \(punctuation)")
                            DispatchQueue.main.async { [weak self] in
                                self?.onImmediateStop?(punctuation)
                            }
                            return nil
                        }
                        break
                    }
                } else if isRefining {
                    // 润色期间仅拦截 ESC 键，不影响用户输入其他内容（Only intercept ESC during refining, doesn't affect other user inputs）
                    if keyCode == FnKeyMonitor.escKeyCode {
                        DebugLog.info("[FnKeyMonitor] >>> ESC 取消润色")
                        DispatchQueue.main.async { [weak self] in
                            self?.onEscPressed?()
                        }
                        return nil
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let option = TriggerKeyOption.option(for: triggerKeyCode)

            // 通用触发键检测：通过 keyCode 精确匹配当前触发键（Generic trigger key detection: match current trigger key by keyCode）
            if keyCode == triggerKeyCode {
                let isActive = flags.contains(option.flagMask)
                // 排除触发键自身 flag 后，检查是否有其他修饰键同时按下（After excluding trigger key's own flag, check if other modifiers are pressed simultaneously）
                let otherMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
                let hasOtherMods = !flags.intersection(otherMods.subtracting(option.flagMask)).isEmpty

                DebugLog.info("[FnKeyMonitor] flagsChanged keyCode=\(keyCode) isActive=\(isActive) hasOtherMods=\(hasOtherMods)")

                if isActive && !triggerIsDown && !hasOtherMods {
                    triggerIsDown = true
                    DebugLog.info("[FnKeyMonitor] >>> 触发键按下 (flagsChanged keyCode=\(keyCode))")
                    onFnDown()
                    return nil
                } else if !isActive && triggerIsDown {
                    triggerIsDown = false
                    DebugLog.info("[FnKeyMonitor] >>> 触发键松开 (flagsChanged keyCode=\(keyCode))")
                    onFnUp()
                    return nil
                }
            }

            // Fn 键 flag-only 备用检测（某些机型 keyCode 不稳定为 63）
            // (Fn key flag-only fallback detection — on some models keyCode is unstable and stays at 63)
            if triggerKeyCode == FnKeyMonitor.fnKeyCode {
                let hasFn = flags.contains(.maskSecondaryFn)
                let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

                if hasFn && !triggerIsDown && !hasOtherModifiers {
                    triggerIsDown = true
                    DebugLog.info("[FnKeyMonitor] >>> Fn 按下 (flagsChanged flags-only 备用)")
                    onFnDown()
                    return nil
                } else if !hasFn && triggerIsDown {
                    triggerIsDown = false
                    DebugLog.info("[FnKeyMonitor] >>> Fn 松开 (flagsChanged flags-only 备用)")
                    onFnUp()
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func typedPunctuation(from event: CGEvent) -> String? {
        let blockedModifiers: CGEventFlags = [.maskCommand, .maskControl]
        guard event.flags.intersection(blockedModifiers).isEmpty else { return nil }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
        guard let nsEvent = NSEvent(cgEvent: event), let characters = nsEvent.characters, !characters.isEmpty else { return nil }
        guard characters.allSatisfy({ PunctuationProcessor.isUserTypedPunctuation($0) }) else { return nil }
        return characters
    }
}
