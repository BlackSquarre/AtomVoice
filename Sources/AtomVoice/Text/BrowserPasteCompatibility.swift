import Cocoa
import ApplicationServices

enum BrowserPasteCompatibility {
    /// Safari 网页和独立 Web App 共用 WebKit，不能依赖 AX 文本写入。
    static func usesNativePaste(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.apple.Safari"
            || bundleID == "com.apple.SafariTechnologyPreview"
            || bundleID.hasPrefix("com.apple.Safari.WebApp.")
    }

    /// AX 菜单修饰位中的 Command 是隐含值；零表示仅 Command，不能匹配粘贴并匹配样式等动作。
    static func isPasteShortcut(character: String?, modifiers: Int?) -> Bool {
        character?.lowercased() == "v" && modifiers == 0
    }

    /// 从原生菜单按快捷键元数据查找，不依赖系统语言，也不打开菜单抢走输入焦点。
    /// 调用者必须在后台执行；跨进程读取设有限时，目标应用无响应时退回原路径。
    static func pasteMenuItem(processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        guard let menuBarValue = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarValue as! AXUIElement
        for topLevel in children(menuBar) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            for menu in children(topLevel) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                for item in children(menu) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                    let character = attribute(item, kAXMenuItemCmdCharAttribute) as? String
                    guard character?.lowercased() == "v" else { continue }
                    let modifiers = attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber
                    if isPasteShortcut(character: character, modifiers: modifiers?.intValue) {
                        AXUIElementSetMessagingTimeout(item, 0.2)
                        return item
                    }
                }
            }
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
