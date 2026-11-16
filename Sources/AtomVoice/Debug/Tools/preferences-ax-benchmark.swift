import AppKit
import ApplicationServices

// 本机验收工具：仅打开/关闭主设置窗口，不访问字段值、密钥、权限或识别服务。
// 记录菜单 action 到可访问窗口出现的时间，不将其当作屏幕绘制完成时间。
func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
guard AXIsProcessTrusted() else { fail("Accessibility is unavailable; no permission was requested.") }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "AtomVoice" }) else {
    fail("AtomVoice is not running.")
}
let previousApp = NSWorkspace.shared.frontmostApplication
defer { previousApp?.activate(options: []) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).isEmpty else {
    fail("Leave existing windows untouched: close them before running this probe.")
}
var settingsAction: AXUIElement?
for bar in children(ax) {
    for item in children(bar) where attribute(item, kAXTitleAttribute) as? String == "AtomVoice" {
        for menu in children(item) {
            settingsAction = children(menu).first {
                attribute($0, kAXMenuItemCmdCharAttribute) as? String == ","
            } ?? settingsAction
        }
    }
}
guard let settingsAction else { fail("Settings menu action was not found.") }
var samples: [Double] = []
for _ in 0..<9 {
    let start = ProcessInfo.processInfo.systemUptime
    guard AXUIElementPerformAction(settingsAction, kAXPressAction as CFString) == .success else {
        fail("Settings action failed.")
    }
    var window: AXUIElement?
    while ProcessInfo.processInfo.systemUptime - start < 5 {
        if let found = (attribute(ax, kAXWindowsAttribute) as? [AXUIElement])?.first {
            window = found
            break
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    guard let window else { fail("Settings window did not become accessible.") }
    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    Thread.sleep(forTimeInterval: 0.15)
    guard let close = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() else {
        fail("Settings close button is unavailable.")
    }
    guard AXUIElementPerformAction(unsafeBitCast(close, to: AXUIElement.self), kAXPressAction as CFString) == .success else {
        fail("Could not close the probe window.")
    }
    Thread.sleep(forTimeInterval: 0.15)
}
let repeated = Array(samples.dropFirst()).sorted()
let report: [String: Any] = [
    "scope": "Existing running app: Settings menu action to AX window availability. First probe opening is not a cold launch. Excludes screen drawing completion and connection/model subpages.",
    "pid": app.processIdentifier, "first_probe_open_ms": samples[0],
    "repeated_open_median_ms": (repeated[3] + repeated[4]) / 2,
    "samples_ms": samples,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
