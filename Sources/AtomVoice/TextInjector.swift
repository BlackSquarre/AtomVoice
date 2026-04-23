import Cocoa
import Carbon

final class TextInjector {
    func inject(text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = savePasteboard(pasteboard)

        // Set text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
                }
            }
        }
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
