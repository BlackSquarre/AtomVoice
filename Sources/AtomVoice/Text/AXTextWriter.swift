import Cocoa
import ApplicationServices

// AX 文本写入工具：通过 Accessibility API 直接在聚焦的输入框中插入/替换文本
// (AX text writer: directly insert/replace text in the focused field via the Accessibility API)
final class AXTextWriter {

    /// 已知 AX 写入不可靠的 app bundle ID
    /// 这些 app 的 AXIsAttributeSettable 会返回 true，但 SetSelectedText 实际行为不符合预期：
    /// - 终端类（iTerm2 / Terminal）：选区设置无效，文本只会在光标处追加，导致流式上屏看起来像重复
    /// - 浏览器（Safari / Chrome）：网页 contenteditable 不接受 AX 写入，调用静默失败
    /// 命中黑名单时强制走 Paste 兜底
    /// (Apps where AX text writes are unreliable. AXIsAttributeSettable returns true but
    ///  SetSelectedText doesn't behave as expected:
    ///  - Terminals: selection range is ignored, text just appends → looks duplicated for streaming
    ///  - Browsers: web contenteditable rejects AX writes silently
    ///  Hit list forces fallback to paste path.)
    private static let unreliableAXBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "org.mozilla.firefox",
    ]

    /// 当前聚焦的元素（每次写入前重新获取，避免引用过期）
    /// (Currently focused element — re-fetched before every write to avoid stale references)
    private static func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    /// 探测当前聚焦元素是否支持 AX 直接写文本（决定走 AX 路径还是 Paste 路径）
    /// (Probe whether the focused element supports direct AX text writes — decides AX vs Paste path)
    static func canWriteFocusedElement() -> Bool {
        // 黑名单优先：已知不可靠的 app 直接走兜底
        // (Blacklist first: known-unreliable apps fall back regardless of writability flag)
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           unreliableAXBundleIDs.contains(bundleID) {
            return false
        }
        guard let element = copyFocusedElement() else { return false }
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    /// 获取当前光标位置（UTF-16 偏移；选区时返回 location）
    /// (Get current caret position as UTF-16 offset; returns location when a selection is present)
    static func currentCaretLocation() -> Int? {
        guard let element = copyFocusedElement() else { return nil }
        var rangeRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard status == .success, let rangeRef else { return nil }
        var range = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        return range.location
    }

    /// 在光标处插入 text（不影响选区前后内容）
    /// (Insert text at the caret without affecting content before/after the caret)
    @discardableResult
    static func insertAtCaret(_ text: String) -> Bool {
        guard let element = copyFocusedElement() else { return false }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return status == .success
    }

    /// 选中 [location, location+length) 区间，并用 newText 替换之
    /// 一次完成"选中+替换"，目标 App 视觉上是瞬间完成
    /// (Select [location, location+length) and replace with newText.
    ///  Selection + replacement done in one shot — visually instant in the target app.)
    @discardableResult
    static func replaceRange(location: Int, length: Int, with newText: String) -> Bool {
        guard length > 0 else {
            return insertAtCaret(newText)
        }
        guard let element = copyFocusedElement() else { return false }

        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }

        let selectStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        guard selectStatus == .success else { return false }

        let replaceStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFString)
        return replaceStatus == .success
    }
}
