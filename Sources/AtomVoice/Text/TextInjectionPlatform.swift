import Cocoa
import Carbon

struct TextInjectionTarget {
    let processID: pid_t?
    let bundleID: String?
    let profile: PasteCompatibilityProfile?
}

struct TextInjectionInputSource {
    let needsSwitch: Bool
    let restore: () -> Void
}

/// 平台动作与事务分开；离线测试不读取真实剪贴板、输入法或目标应用。
protocol TextInjectionPlatform: AnyObject {
    func target() -> TextInjectionTarget
    func frontmostProcessID() -> pid_t?
    func preparePaste(for target: TextInjectionTarget) async -> @MainActor () async -> TextDeliverySubmission
    func textForInsertion(_ text: String, targetPID: pid_t?) async -> String
    func prepareInputSource() -> TextInjectionInputSource
}

final class SystemTextInjectionPlatform: TextInjectionPlatform {
    func target() -> TextInjectionTarget {
        let profile = PasteCompatibilityRegistry.profileForFrontmostApp()
        let app = NSWorkspace.shared.frontmostApplication
        return .init(processID: app?.processIdentifier, bundleID: app?.bundleIdentifier, profile: profile)
    }

    func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func preparePaste(for target: TextInjectionTarget) async -> @MainActor () async -> TextDeliverySubmission {
        let nativePID = BrowserPasteCompatibility.usesNativePaste(bundleID: target.bundleID) ? target.processID : nil
        let menuItem = await Task.detached(priority: .userInitiated) {
            nativePID.flatMap { BrowserPasteCompatibility.pasteMenuItem(processID: $0) }
        }.value
        return { [self] in
            if let menuItem {
                guard frontmostProcessID() == nativePID else { return .notSubmitted }
                let status = await Task.detached(priority: .userInitiated) {
                    AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                }.value
                if status != .success {
                    // AX 超时也可能已经执行，不再补发 Command+V。
                    DebugLog.error("[TextInjector] Native browser paste failed status=\(status.rawValue)")
                }
                return .eventPosted
            }
            return Self.simulatePaste() ? .eventPosted : .notSubmitted
        }
    }

    func textForInsertion(_ text: String, targetPID: pid_t?) async -> String {
        let probe = Task.detached(priority: .userInitiated) {
            CursorPunctuationProbe.textForInsertion(text, targetPID: targetPID,
                access: SystemCursorPunctuationAccess(), isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler(operation: { await probe.value }, onCancel: { probe.cancel() })
    }

    func prepareInputSource() -> TextInjectionInputSource {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needsSwitch = Self.isCJKInputSource(original)
        if needsSwitch { Self.switchToASCIIInputSource() }
        return .init(needsSwitch: needsSwitch, restore: {
            if needsSwitch { TISSelectInputSource(original) }
        })
    }

    private static func isCJKInputSource(_ source: TISInputSource) -> Bool {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

        let cjkPatterns = [
            "com.apple.inputmethod.SCIM",   // 简体中文（Simplified Chinese）
            "com.apple.inputmethod.TCIM",   // 繁体中文（Traditional Chinese）
            "com.apple.inputmethod.Japanese",// 日文（Japanese）
            "com.apple.inputmethod.Korean",  // 韩文（Korean）
            "com.apple.inputmethod.ChineseHandwriting",// 中文手写（Chinese Handwriting）
            "com.google.inputmethod.Japanese",// 日文（Japanese）
            "com.sogou.inputmethod",
            "com.baidu.inputmethod",
            "com.tencent.inputmethod",
        ]

        return cjkPatterns.contains(where: { sourceID.hasPrefix($0) })
    }

    private static func switchToASCIIInputSource() {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout,
        ] as CFDictionary

        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        // 优先选择 ABC 或 US 键盘布局（Prefer ABC or US keyboard layout）
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for prefID in preferred {
            if let source = sources.first(where: { source in
                guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                return id == prefID
            }) {
                TISSelectInputSource(source)
                return
            }
        }

        // 回退：选择第一个支持 ASCII 的键盘布局 (Fallback: select first ASCII-capable keyboard layout)
        if let asciiCapableSource = sources.first(where: { source in
            guard let capablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
            return Unmanaged<CFBoolean>.fromOpaque(capablePtr).takeUnretainedValue() == kCFBooleanTrue
        }) {
            TISSelectInputSource(asciiCapableSource)
            return
        }

        // 最终回退：选择第一个可用的输入源（Fallback: select first available source）
        if let first = sources.first {
            TISSelectInputSource(first)
        }
    }

    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V 键（V key）
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        guard let keyDown, let keyUp else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

}
