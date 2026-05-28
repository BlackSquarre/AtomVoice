import Cocoa
import Carbon

final class TextInjector {
    private struct PendingInjection {
        let text: String
        let completion: (() -> Void)?
    }

    private static let injectionWatchdogTimeout: TimeInterval = 5.0

    private var pendingInjections: [PendingInjection] = []
    private var isInjecting = false
    private var currentInjectionID = UUID()

    func inject(text: String, completion: (() -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [self] in
                inject(text: text, completion: completion)
            }
            return
        }

        pendingInjections.append(PendingInjection(text: text, completion: completion))
        processNextInjection()
    }

    private func processNextInjection() {
        guard !isInjecting, !pendingInjections.isEmpty else { return }

        let next = pendingInjections.removeFirst()
        guard !next.text.isEmpty else {
            next.completion?()
            processNextInjection()
            return
        }

        isInjecting = true
        let injectionID = UUID()
        currentInjectionID = injectionID
        let text = next.text
        let completion = next.completion

        // 主任务：跑完整粘贴流程，结束后在主线程上回收状态并推进队列。
        // (Main task: run the full paste pipeline, then reconcile state on main thread.)
        Task { @MainActor [weak self] in
            await self?.performInject(text: text)
            self?.finishInjection(injectionID: injectionID, completion: completion)
        }

        // Watchdog：5s 内未完成就强制回收状态、调 completion、继续推进。
        // 与主任务用 injectionID 互相 gate，先到的一方负责调 completion。
        // (Watchdog: force-reset and continue after 5s. Two tasks gate each other via injectionID;
        //  whoever wins fires completion.)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.injectionWatchdogTimeout * 1_000_000_000))
            self?.handleWatchdog(injectionID: injectionID, textLength: text.count, completion: completion)
        }
    }

    @MainActor
    private func finishInjection(injectionID: UUID, completion: (() -> Void)?) {
        guard isInjecting, currentInjectionID == injectionID else { return }
        isInjecting = false
        completion?()
        processNextInjection()
    }

    @MainActor
    private func handleWatchdog(injectionID: UUID, textLength: Int, completion: (() -> Void)?) {
        guard isInjecting, currentInjectionID == injectionID else { return }
        DebugLog.error("[TextInjector] Injection timed out after \(Self.injectionWatchdogTimeout)s, resetting state and continuing queue, textLength=\(textLength)")
        isInjecting = false
        currentInjectionID = UUID()
        completion?()
        processNextInjection()
    }

    @MainActor
    private func performInject(text: String) async {
        // 在主线程上读取前台应用的 bundleID，命中内置兼容性清单时改用更长的粘贴延迟，避免远程桌面/虚拟机/串流类应用丢字符。
        // (Resolve frontmost app on main thread to pick per-app paste delay override for remote desktop / VM / streaming clients.)
        let compatProfile: PasteCompatibilityProfile? = PasteCompatibilityRegistry.profileForFrontmostApp()

        // 将获取光标后字符的跨进程 IPC 调用移至后台 Task，避免目标应用挂起时连带卡死主线程。
        // (Move the cross-process AX read off the main actor so a hung target app doesn't freeze us.)
        let nextChar = await Task.detached(priority: .userInitiated) {
            Self.getCharacterAfterCursor()
        }.value

        var finalText = text
        if let nextChar, PunctuationProcessor.isSentenceEndingPunctuation(nextChar) {
            finalText = Self.removeTrailingPunctuation(text)
        }

        // 保存当前剪贴板（Save current clipboard）
        let pasteboard = NSPasteboard.general
        let previousContents = savePasteboard(pasteboard)

        // 将文本写入剪贴板（Set text to clipboard）
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)

        // 检查当前输入源是否为 CJK，如需要则切换到 ASCII（Check current input source, switch to ASCII if needed）
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needsSwitch = Self.isCJKInputSource(originalSource)
        if needsSwitch {
            Self.switchToASCIIInputSource()
        }

        // 短暂等待输入源切换生效（Wait briefly for input source switch to take effect）
        await Self.sleep(seconds: needsSwitch ? 0.05 : 0.02)
        Self.simulatePaste()

        // 粘贴延迟：给目标 App（含 Electron 等慢应用）足够时间完成粘贴；debug build 可在菜单调节。
        // 远程桌面 / 虚拟机 / 串流类应用命中兼容性清单时使用更长的延迟，避免键盘转发掉字符。
        // (Paste delay: enough time for target apps incl. Electron; tunable via debug menu.
        //  Remote-desktop / VM / streaming clients matched by compatibility registry use a longer override to avoid dropped characters.)
        let pasteDelay = max(AppSettings.pasteDelay, compatProfile?.pasteDelay ?? 0)
        await Self.sleep(seconds: pasteDelay)

        if needsSwitch {
            TISSelectInputSource(originalSource)
        }

        // 再等一帧后恢复剪贴板，确保输入法恢复不影响粘贴（Wait one more frame before restoring pasteboard）
        await Self.sleep(seconds: 0.05)
        restorePasteboard(pasteboard, contents: previousContents)
    }

    private static func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 光标标点检测

    /// 获取当前聚焦输入框中光标后方的第一个字符（Get the first character after cursor in the currently focused text field）
    private static func getCharacterAfterCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()

        // 获取当前聚焦的 UI 元素（Get the currently focused UI element）
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focusedElement = focused else { return nil }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        let focusedUIElement = focusedElement as! AXUIElement

        // 获取选区范围（光标位置）（Get selection range / cursor position）
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focusedUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success, let range = selectedRange else { return nil }

        guard CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        let axValue = range as! AXValue
        var rangeValue = CFRange()
        AXValueGetValue(axValue, .cfRange, &rangeValue)

        // 获取输入框文本内容（Get text field content）
        var value: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(focusedUIElement, kAXValueAttribute as CFString, &value)
        guard textResult == .success, let text = value as? String else { return nil }

        // 计算光标后方位置（Calculate position after cursor）
        // AX API 的 CFRange 使用 UTF-16 偏移，需用 UTF16View 索引（AX API's CFRange uses UTF-16 offsets, must use UTF16View indexing）
        let utf16 = text.utf16
        let nextIndex = rangeValue.location + rangeValue.length
        guard nextIndex >= 0, nextIndex < utf16.count else { return nil }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: nextIndex)
        guard let charIndex = utf16Index.samePosition(in: text) else { return nil }
        return text[charIndex]
    }

    /// 移除文本末尾的标点符号（Remove trailing punctuation from text）
    private static func removeTrailingPunctuation(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
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

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V 键（V key）
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Pasteboard Save/Restore

    private struct PasteboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[PasteboardItem]] {
        var allItems: [[PasteboardItem]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [PasteboardItem] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append(PasteboardItem(type: type, data: data))
                }
            }
            allItems.append(itemData)
        }
        return allItems
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, contents: [[PasteboardItem]]) {
        pasteboard.clearContents()
        if contents.isEmpty { return }

        var items: [NSPasteboardItem] = []
        for itemData in contents {
            let item = NSPasteboardItem()
            for entry in itemData {
                item.setData(entry.data, forType: entry.type)
            }
            items.append(item)
        }
        pasteboard.writeObjects(items)
    }
}
