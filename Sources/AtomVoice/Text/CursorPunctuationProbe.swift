import Cocoa

/// 只暴露光标附近的查询能力，探测与测试都不能退回读取输入框全文。
protocol CursorPunctuationAccess {
    associatedtype Element
    func application(processID: pid_t) -> Element
    func focusedElement(in application: Element, timeout: TimeInterval) -> Element?
    func selectedRange(in element: Element, timeout: TimeInterval) -> CFRange?
    func composedRange(at index: Int, in element: Element, timeout: TimeInterval) -> CFRange?
    func string(in range: CFRange, element: Element, timeout: TimeInterval) -> String?
    func sameElement(_ first: Element, _ second: Element) -> Bool
}

enum CursorPunctuationProbe {
    static let maximumUTF16Length = 16
    static let totalBudget: TimeInterval = 0.08
    private static let messageBudget: TimeInterval = 0.025

    static func needsLookup(_ text: String) -> Bool {
        text.last.map(PunctuationProcessor.isSentenceEndingPunctuation) ?? false
    }

    /// 同步 AX 不能被 Task.cancel 强行中断；逐次限制消息超时，返回后再次核对总预算与取消状态。
    static func textForInsertion<Access: CursorPunctuationAccess>(
        _ text: String,
        targetPID: pid_t?,
        access: Access,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isCancelled: () -> Bool = { false }
    ) -> String {
        guard needsLookup(text), let targetPID, targetPID > 0, !isCancelled() else { return text }
        let deadline = now() + totalBudget
        func timeout() -> TimeInterval? {
            let remaining = deadline - now()
            guard !isCancelled(), remaining.isFinite, remaining > 0 else { return nil }
            return min(messageBudget, remaining)
        }

        let application = access.application(processID: targetPID)
        guard let focusTimeout = timeout(),
              let element = access.focusedElement(in: application, timeout: focusTimeout),
              let selectionTimeout = timeout(),
              let selection = access.selectedRange(in: element, timeout: selectionTimeout),
              let end = checkedEnd(of: selection),
              let rangeTimeout = timeout(),
              let range = access.composedRange(at: end, in: element, timeout: rangeTimeout),
              range.location == end, range.length > 0, range.length <= maximumUTF16Length,
              checkedEnd(of: range) != nil,
              let stringTimeout = timeout(),
              let localText = access.string(in: range, element: element, timeout: stringTimeout),
              localText.utf16.count == range.length, localText.count == 1,
              let character = localText.first,
              PunctuationProcessor.isSentenceEndingPunctuation(character),
              let recheckFocusTimeout = timeout(),
              let currentElement = access.focusedElement(in: application, timeout: recheckFocusTimeout),
              access.sameElement(element, currentElement),
              let recheckSelectionTimeout = timeout(),
              let currentSelection = access.selectedRange(in: element, timeout: recheckSelectionTimeout),
              currentSelection.location == selection.location,
              currentSelection.length == selection.length,
              timeout() != nil else { return text }

        // 保留旧语义：目标侧有任一句末标点，就移除待插入文本连续的句末标点；不 trim 空白。
        var endIndex = text.endIndex
        while endIndex > text.startIndex {
            let previous = text.index(before: endIndex)
            guard PunctuationProcessor.isSentenceEndingPunctuation(text[previous]) else { break }
            endIndex = previous
        }
        return String(text[..<endIndex])
    }

    private static func checkedEnd(of range: CFRange) -> Int? {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow && end != NSNotFound ? end : nil
    }
}

struct SystemCursorPunctuationAccess: CursorPunctuationAccess {
    func application(processID: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(processID)
    }

    func focusedElement(in application: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        guard setTimeout(timeout, on: application) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func selectedRange(in element: AXUIElement, timeout: TimeInterval) -> CFRange? {
        guard setTimeout(timeout, on: element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success else {
            return nil
        }
        return Self.decodeRange(value)
    }

    func composedRange(at index: Int, in element: AXUIElement, timeout: TimeInterval) -> CFRange? {
        guard setTimeout(timeout, on: element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForIndexParameterizedAttribute as CFString,
                                                         NSNumber(value: index), &value) == .success else { return nil }
        return Self.decodeRange(value)
    }

    func string(in range: CFRange, element: AXUIElement, timeout: TimeInterval) -> String? {
        guard setTimeout(timeout, on: element) else { return nil }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success else { return nil }
        return value as? String
    }

    func sameElement(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    /// 超时只设置在本次创建或返回的实际对象上，不能改变进程的全局 AX 超时。
    private func setTimeout(_ timeout: TimeInterval, on element: AXUIElement) -> Bool {
        timeout > 0 && AXUIElementSetMessagingTimeout(element, Float(timeout)) == .success
    }

    static func decodeRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
