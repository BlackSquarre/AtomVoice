import Cocoa
import Carbon

final class TextInjector {
    private struct PendingInjection {
        let text: String
        let completion: (() -> Void)?
    }

    private var pendingInjections: [PendingInjection] = []
    private var isInjecting = false

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
        performInject(text: next.text) { [weak self] in
            guard let self else { return }
            self.isInjecting = false
            next.completion?()
            self.processNextInjection()
        }
    }

    private func performInject(text: String, completion: (() -> Void)? = nil) {
        // 将获取光标后字符的跨进程 IPC 调用移至后台队列，避免目标应用挂起时连带卡死主线程
        // (Move the cross-process IPC call for getting character after cursor to a background queue to avoid freezing the main thread if target app hangs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let nextChar = self.getCharacterAfterCursor()
            
            DispatchQueue.main.async {
                var finalText = text
                if let nextChar, PunctuationProcessor.isSentenceEndingPunctuation(nextChar) {
                    finalText = self.removeTrailingPunctuation(text)
                }

                // 保存当前剪贴板（Save current clipboard）
                let pasteboard = NSPasteboard.general
                let previousContents = self.savePasteboard(pasteboard)

                // 将文本写入剪贴板（Set text to clipboard）
                pasteboard.clearContents()
                pasteboard.setString(finalText, forType: .string)

                // 检查当前输入源是否为 CJK，如需要则切换到 ASCII（Check if current input source is CJK, switch to ASCII if needed）
                let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
                let needsSwitch = self.isCJKInputSource(originalSource)
                if needsSwitch {
                    self.switchToASCIIInputSource()
                }

                // 短暂延迟，等待输入源切换生效（Small delay for input source switch to take effect）
                let delay = needsSwitch ? 0.05 : 0.02
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // 模拟 Cmd+V 粘贴（Simulate Cmd+V paste）
                    self.simulatePaste()

                    // 粘贴后恢复输入源（Restore input source after paste）
                    // 粘贴延迟：给目标 App（含 Electron 等慢应用）足够时间完成粘贴（Paste delay: give target apps including Electron enough time to complete paste）
                    let pasteDelay: Double = 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
                        if needsSwitch {
                            TISSelectInputSource(originalSource)
                        }
                        // 再等一帧后恢复剪贴板，确保输入法恢复不影响粘贴（Wait one more frame before restoring pasteboard, ensuring input method restoration doesn't affect paste）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.restorePasteboard(pasteboard, contents: previousContents)
                            completion?()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 光标标点检测

    /// 获取当前聚焦输入框中光标后方的第一个字符（Get the first character after cursor in the currently focused text field）
    private func getCharacterAfterCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()

        // 获取当前聚焦的 UI 元素（Get the currently focused UI element）
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focusedElement = focused else { return nil }

        // 获取选区范围（光标位置）（Get selection range / cursor position）
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success, let range = selectedRange else { return nil }

        var rangeValue = CFRange()
        AXValueGetValue(range as! AXValue, .cfRange, &rangeValue)

        // 获取输入框文本内容（Get text field content）
        var value: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXValueAttribute as CFString, &value)
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
    private func removeTrailingPunctuation(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    private func isCJKInputSource(_ source: TISInputSource) -> Bool {
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

    private func switchToASCIIInputSource() {
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

    private func simulatePaste() {
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
