import Cocoa

final class FnKeyMonitor {
    private let onFnDown: () -> Void
    private let onFnUp: () -> Void
    var onTapDisabled: (() -> Void)?  // 权限丢失时通知外部

    // 录音期间的按键回调
    var onEscPressed: (() -> Void)?         // ESC 取消录音
    var onImmediateStop: (() -> Void)?      // Space/Backspace 立即上屏
    var isRecording = false                  // 由 AppDelegate 设置

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

    private static let fnKeyCode: UInt16 = 0x3F  // 63
    private static let escKeyCode: UInt16 = 0x35  // 53
    private static let spaceKeyCode: UInt16 = 0x31  // 49
    private static let backspaceKeyCode: UInt16 = 0x33  // 51

    init(onFnDown: @escaping () -> Void, onFnUp: @escaping () -> Void) {
        self.onFnDown = onFnDown
        self.onFnUp = onFnUp
    }

    func start() {
        // 监听按键 + 修饰键 + 系统定义事件（NX_SYSDEFINED = 14，Globe 键行为通过此事件触发）
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
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[FnKeyMonitor] 无法创建事件监听。请在系统设置 > 隐私与安全性 > 辅助功能中授权本应用。")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[FnKeyMonitor] 事件监听已启动")
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
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[FnKeyMonitor] 事件 tap 被系统禁用，正在重启...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onTapDisabled?()
                    }
                }
            }
            return Unmanaged.passRetained(event)
        }

        // 拦截 NX_SYSDEFINED（type 14）：Globe 键触发字符检视器的系统事件
        if type.rawValue == 14 {
            let flags = event.flags
            if flags.contains(.maskSecondaryFn) {
                print("[FnKeyMonitor] 拦截 NX_SYSDEFINED (Fn/Globe)")
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let hasFn = flags.contains(.maskSecondaryFn)

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == FnKeyMonitor.fnKeyCode || hasFn {
                print("[FnKeyMonitor] \(type == .keyDown ? "keyDown" : "keyUp") keyCode=\(keyCode) flags=\(flags.rawValue) hasFn=\(hasFn)")
            }

            // 拦截 Fn/Globe 键（keycode 63）
            if keyCode == FnKeyMonitor.fnKeyCode {
                if type == .keyDown && !fnIsDown {
                    fnIsDown = true
                    print("[FnKeyMonitor] >>> Fn 按下 (via keyDown)")
                    onFnDown()
                } else if type == .keyUp && fnIsDown {
                    fnIsDown = false
                    print("[FnKeyMonitor] >>> Fn 松开 (via keyUp)")
                    onFnUp()
                }
                return nil
            }

            // 录音期间拦截特殊按键（仅 keyDown）
            if type == .keyDown && isRecording {
                switch keyCode {
                case FnKeyMonitor.escKeyCode:
                    print("[FnKeyMonitor] >>> ESC 取消录音")
                    DispatchQueue.main.async { [weak self] in
                        self?.onEscPressed?()
                    }
                    return nil  // 吞掉 ESC

                case FnKeyMonitor.spaceKeyCode, FnKeyMonitor.backspaceKeyCode:
                    print("[FnKeyMonitor] >>> Space/Backspace 立即上屏")
                    DispatchQueue.main.async { [weak self] in
                        self?.onImmediateStop?()
                    }
                    return nil  // 吞掉按键

                default:
                    break
                }
            }

            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

            print("[FnKeyMonitor] flagsChanged keyCode=\(keyCode) flags=\(flags.rawValue) hasFn=\(hasFn) hasOther=\(hasOtherModifiers)")

            // 方式 1: 通过 keyCode 63 判断
            if keyCode == FnKeyMonitor.fnKeyCode {
                if hasFn && !fnIsDown && !hasOtherModifiers {
                    fnIsDown = true
                    print("[FnKeyMonitor] >>> Fn 按下 (via flagsChanged keyCode)")
                    onFnDown()
                } else if !hasFn && fnIsDown {
                    fnIsDown = false
                    print("[FnKeyMonitor] >>> Fn 松开 (via flagsChanged keyCode)")
                    onFnUp()
                }
                return nil
            }

            // 方式 2: 纯 flag 判断（备用，某些机型 keyCode 不是 63）
            if hasFn && !fnIsDown && !hasOtherModifiers {
                fnIsDown = true
                print("[FnKeyMonitor] >>> Fn 按下 (via flagsChanged flags-only)")
                onFnDown()
                return nil
            } else if !hasFn && fnIsDown {
                fnIsDown = false
                print("[FnKeyMonitor] >>> Fn 松开 (via flagsChanged flags-only)")
                onFnUp()
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }
}
