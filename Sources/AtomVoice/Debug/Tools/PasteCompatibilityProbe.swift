#!/usr/bin/swift

import Cocoa
import ApplicationServices

struct PasteCase {
    let name: String
    let bundleID: String
}

struct PasteResult {
    let name: String
    let bundleID: String
    let electron: Bool
    let menu: String
    let input: String
    let outcome: String
}

let cases = [
    PasteCase(name: "ChatGPT", bundleID: "com.openai.codex"),
    PasteCase(name: "Hermes", bundleID: "com.nousresearch.hermes"),
    PasteCase(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
    PasteCase(name: "Antigravity", bundleID: "com.google.antigravity"),
    PasteCase(name: "Discord", bundleID: "com.hnc.Discord"),
    PasteCase(name: "Obsidian", bundleID: "md.obsidian"),
    PasteCase(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
    PasteCase(name: "OpenCode", bundleID: "ai.opencode.desktop"),
    PasteCase(name: "LM Studio", bundleID: "ai.elementlabs.lmstudio"),
    PasteCase(name: "Google Chrome", bundleID: "com.google.Chrome"),
    PasteCase(name: "Safari", bundleID: "com.apple.Safari"),
    PasteCase(name: "Hermes Dashboard", bundleID: "com.apple.Safari.WebApp.E59F6913-97EF-4C2F-B670-0530F7C1D80B"),
]

let shouldDump = CommandLine.arguments.contains("--dump")
let showHelp = CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h")
let axEditableAttribute = "AXEditable"
let onlyBundleID = CommandLine.arguments.first { $0.hasPrefix("--only=") }?.dropFirst("--only=".count)
let selectedCases = onlyBundleID.map { bundleID in
    cases.filter { $0.bundleID == bundleID }
} ?? cases

let pasteboard = NSPasteboard.general
let originalItems = pasteboard.pasteboardItems?.map { item in
    item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
    }
} ?? []

func restorePasteboard() {
    pasteboard.clearContents()
    var restoredItems: [NSPasteboardItem] = []
    for itemData in originalItems {
        let item = NSPasteboardItem()
        for (type, data) in itemData {
            item.setData(data, forType: type)
        }
        restoredItems.append(item)
    }
    pasteboard.writeObjects(restoredItems)
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    copyAttribute(element, name) as? String ?? ""
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
    (copyAttribute(element, name) as? NSNumber)?.boolValue ?? false
}

func children(of element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func descendants(of root: AXUIElement, limit: Int = 2500, skipMenus: Bool = true) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    while !queue.isEmpty && result.count < limit {
        let (element, depth) = queue.removeFirst()
        result.append(element)
        guard depth < 14 else { continue }
        let role = stringAttribute(element, kAXRoleAttribute)
        if skipMenus && (role == kAXMenuBarRole || role == kAXMenuRole || role == kAXMenuItemRole) { continue }
        queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
    }
    return result
}

func isElectron(_ app: NSRunningApplication) -> Bool {
    guard let bundleURL = app.bundleURL else { return false }
    let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
    return FileManager.default.fileExists(atPath: framework.path)
}

func launchAndActivate(_ bundleID: String) -> NSRunningApplication? {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate(options: [.activateAllWindows])
    } else {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        try? process.run()
    }

    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier == bundleID {
            return app
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        ? NSWorkspace.shared.frontmostApplication
        : nil
}

func scoreInput(_ element: AXUIElement) -> (Int, String) {
    let role = stringAttribute(element, kAXRoleAttribute)
    let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute)
    let description = stringAttribute(element, kAXDescriptionAttribute)
    let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute)
    let value = stringAttribute(element, kAXValueAttribute)
    let editable = boolAttribute(element, axEditableAttribute)
    let standardTextRole = role == kAXTextAreaRole || role == kAXTextFieldRole
    let textRoleDescription = roleDescription.lowercased().contains("text field")
        || roleDescription.lowercased().contains("text area")
        || roleDescription.lowercased().contains("textbox")
    guard standardTextRole || textRoleDescription || editable else { return (-1, "") }
    let text = "\(description) \(placeholder) \(roleDescription)".lowercased()
    let preferred = ["message", "prompt", "消息", "输入", "task", "任务", "ask", "question"]
    let rejected = ["search", "搜索", "address", "地址", "url"]
    var score = role == kAXTextAreaRole || textRoleDescription ? 30 : 10
    for term in preferred where text.contains(term) { score += 100 }
    for term in rejected where text.contains(term) { score -= 80 }
    if !value.isEmpty { score += 5 }
    if editable { score += 20 }
    return (score, description.isEmpty ? (placeholder.isEmpty ? roleDescription : placeholder) : description)
}

func dumpAccessibilityTree(for appElement: AXUIElement, appName: String) {
    var roleCounts: [String: Int] = [:]
    let nodes = windowElements(of: appElement).flatMap { descendants(of: $0) }
    for element in nodes {
        let role = stringAttribute(element, kAXRoleAttribute)
        roleCounts[role, default: 0] += 1
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute)
        let description = stringAttribute(element, kAXDescriptionAttribute)
        let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute)
        let editable = boolAttribute(element, axEditableAttribute)
        let value = stringAttribute(element, kAXValueAttribute)
        let focused = boolAttribute(element, kAXFocusedAttribute)
        let interesting = editable || !placeholder.isEmpty || !description.isEmpty
            || roleDescription.lowercased().contains("text")
            || role.lowercased().contains("text")
        if interesting {
            print("DUMP|\(appName)|role=\(role)|roleDescription=\(roleDescription)|description=\(description)|placeholder=\(placeholder)|editable=\(editable)|focused=\(focused)|valueLength=\(value.count)")
        }
    }
    let counts = roleCounts.keys.sorted().map { "\($0)=\(roleCounts[$0] ?? 0)" }.joined(separator: ",")
    print("DUMP|\(appName)|nodes=\(nodes.count)|roles=\(counts)")
    if let focusedValue = copyAttribute(appElement, kAXFocusedUIElementAttribute),
       CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
        let focused = focusedValue as! AXUIElement
        print("DUMP|\(appName)|focusedRole=\(stringAttribute(focused, kAXRoleAttribute))|focusedDescription=\(stringAttribute(focused, kAXDescriptionAttribute))|focusedValueLength=\(stringAttribute(focused, kAXValueAttribute).count)")
    }
}

func windowElements(of appElement: AXUIElement) -> [AXUIElement] {
    copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

func findInput(in appElement: AXUIElement) -> (AXUIElement, String)? {
    windowElements(of: appElement).flatMap { descendants(of: $0) }.compactMap { element in
        let scored = scoreInput(element)
        return scored.0 > 0 ? (scored.0, element, scored.1) : nil
    }.sorted { $0.0 > $1.0 }.first.map { ($0.1, $0.2) }
}

func findPasteMenu(in appElement: AXUIElement) -> AXUIElement? {
    guard let menuBarValue = copyAttribute(appElement, kAXMenuBarAttribute),
          CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
    let menuBar = menuBarValue as! AXUIElement
    for element in descendants(of: menuBar, limit: 600, skipMenus: false) {
        guard stringAttribute(element, kAXRoleAttribute) == kAXMenuItemRole else { continue }
        let character = stringAttribute(element, kAXMenuItemCmdCharAttribute).lowercased()
        let modifiers = (copyAttribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
        if character == "v" && modifiers == 0 { return element }
    }
    return nil
}

func pressCommandZ() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    let down = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func test(_ testCase: PasteCase) -> PasteResult {
    guard let app = launchAndActivate(testCase.bundleID) else {
        return PasteResult(name: testCase.name, bundleID: testCase.bundleID, electron: false, menu: "unavailable", input: "unavailable", outcome: "SKIP app not frontmost")
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.25)
    let electron = isElectron(app)
    let menuItem = findPasteMenu(in: appElement)
    let menuStatus = menuItem == nil ? "missing" : "found"
    if shouldDump { dumpAccessibilityTree(for: appElement, appName: testCase.name) }
    guard let menuItem else {
        return PasteResult(name: testCase.name, bundleID: testCase.bundleID, electron: electron, menu: menuStatus, input: "not-tested", outcome: "SKIP paste menu missing")
    }
    guard let (input, inputDescription) = findInput(in: appElement) else {
        return PasteResult(name: testCase.name, bundleID: testCase.bundleID, electron: electron, menu: menuStatus, input: "missing", outcome: "SKIP editable input missing")
    }
    let marker = "ATOMVOICE_AX_PASTE_PROBE_\(UUID().uuidString)"
    pasteboard.clearContents()
    pasteboard.setString(marker, forType: .string)
    let originalValue = copyAttribute(input, kAXValueAttribute) as? String ?? ""
    let focus = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focus == .success else {
        restorePasteboard()
        return PasteResult(name: testCase.name, bundleID: testCase.bundleID, electron: electron, menu: menuStatus, input: inputDescription, outcome: "SKIP input focus failed")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    let pressStatus = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let valueAfterPaste = copyAttribute(input, kAXValueAttribute) as? String ?? ""
    let found = valueAfterPaste.contains(marker)
    if found { pressCommandZ() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    let valueAfterUndo = copyAttribute(input, kAXValueAttribute) as? String ?? ""
    restorePasteboard()
    let cleanupStatus = found && (valueAfterUndo == originalValue || !valueAfterUndo.contains(marker))
    let outcome = pressStatus == .success && found && cleanupStatus
        ? "PASS AXPress + marker verified + undo verified"
        : "FAIL press=\(pressStatus.rawValue) marker=\(found) cleanup=\(cleanupStatus)"
    return PasteResult(name: testCase.name, bundleID: testCase.bundleID, electron: electron, menu: menuStatus, input: inputDescription, outcome: outcome)
}

defer { restorePasteboard() }
if showHelp {
    print("Usage: test_paste_compatibility.sh [--dump] [--only=BUNDLE_ID]")
    print("  --dump  输出每个应用的 AX 窗口节点诊断信息")
    print("  --only  只测试指定 bundle ID")
} else {
    print("AtomVoice Accessibility Paste Probe")
    print("testCount=\(selectedCases.count)")
    for testCase in selectedCases {
        let result = test(testCase)
        print("\(result.name)\t\(result.bundleID)\telectron=\(result.electron)\tmenu=\(result.menu)\tinput=\(result.input)\t\(result.outcome)")
    }
}
