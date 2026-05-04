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
        // 如果光标后方已有标点，则移除注入文本末尾的标点
        var finalText = text
        if let nextChar = getCharacterAfterCursor(),
           PunctuationProcessor.isSentenceEndingPunctuation(nextChar) {
            finalText = removeTrailingPunctuation(text)
        }

        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = savePasteboard(pasteboard)

        // Set text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)

        // Check if current input source is CJK, switch to ASCII if needed
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needsSwitch = isCJKInputSource(originalSource)
        if needsSwitch {
            switchToASCIIInputSource()
        }

        // Small delay for input source switch to take effect
        let delay = needsSwitch ? 0.05 : 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            // Simulate Cmd+V
            simulatePaste()

            // Restore input source after paste
            // 粘贴延迟：给目标 App（含 Electron 等慢应用）足够时间完成粘贴
            let pasteDelay: Double = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
                if needsSwitch {
                    TISSelectInputSource(originalSource)
                }
                // 再等一帧后恢复剪贴板，确保输入法恢复不影响粘贴
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.restorePasteboard(pasteboard, contents: previousContents)
                    completion?()
                }
            }
        }
    }

    // MARK: - 光标标点检测

    /// 获取当前聚焦输入框中光标后方的第一个字符
    private func getCharacterAfterCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()

        // 获取当前聚焦的 UI 元素
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focusedElement = focused else { return nil }

        // 获取选区范围（光标位置）
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success, let range = selectedRange else { return nil }

        var rangeValue = CFRange()
        AXValueGetValue(range as! AXValue, .cfRange, &rangeValue)

        // 获取输入框文本内容
        var value: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXValueAttribute as CFString, &value)
        guard textResult == .success, let text = value as? String else { return nil }

        // 计算光标后方位置
        let nextIndex = rangeValue.location + rangeValue.length
        guard nextIndex >= 0, nextIndex < text.count else { return nil }

        let index = text.index(text.startIndex, offsetBy: nextIndex)
        return text[index]
    }

    /// 移除文本末尾的标点符号
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
            "com.apple.inputmethod.SCIM",   // Simplified Chinese
            "com.apple.inputmethod.TCIM",   // Traditional Chinese
            "com.apple.inputmethod.Japanese",
            "com.apple.inputmethod.Korean",
            "com.apple.inputmethod.ChineseHandwriting",
            "com.google.inputmethod.Japanese",
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

        // Prefer ABC or US keyboard
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

        // Fallback: select first ASCII-capable source
        if let first = sources.first {
            TISSelectInputSource(first)
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
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
