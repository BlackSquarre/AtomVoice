import Cocoa

/// 粘贴兼容性分类。同一类内的应用共享一个粘贴延迟值；后续要调参数只需改类别上的常量。
/// (Paste compatibility categories. All apps in a category share the same paste delay; tuning is done at the category level.)
enum PasteCompatibilityCategory {
    /// 远程桌面 / 远程控制 / VDI / 云桌面：键盘事件走网络，常见 200~400ms 抖动。
    /// (Remote desktop / remote control / VDI / cloud desktop — keyboard events traverse network.)
    case remoteDesktop
    /// 本地虚拟机：键盘事件经过 hypervisor 转发，比远程稍快，但仍快于普通桌面应用。
    /// (Local VM — keyboard forwarded through hypervisor; faster than network but slower than native apps.)
    case virtualMachine
    /// 游戏串流：除转发延迟外还要等下一帧渲染，通常需要最长延迟。
    /// (Game streaming — also waits for next frame render; needs the longest delay.)
    case gameStreaming
    /// Electron / Chromium 套壳应用：粘贴经过渲染进程读剪贴板，标准延迟下可能丢字符或粘贴空。
    /// 沿用历史上验证过对 Electron 有效的 0.25s；全局默认延迟下调后由这里兜底。
    /// (Electron / Chromium shells — paste goes through the renderer reading the clipboard, so the
    ///  short default can drop characters. Keeps the 0.25s value historically proven for Electron.)
    case electron

    /// 该类别下统一使用的粘贴延迟（秒），会与全局 AppSettings.pasteDelay 取较大值。
    /// (Category-wide paste delay in seconds; combined with the global AppSettings.pasteDelay by taking the larger value.)
    var pasteDelay: Double {
        switch self {
        case .electron:       return 0.25
        case .virtualMachine: return 0.35
        case .remoteDesktop:  return 0.40
        case .gameStreaming:  return 0.50
        }
    }
}

/// 针对特定应用的粘贴兼容性条目。
/// (Paste compatibility entry for a specific app.)
struct PasteCompatibilityProfile {
    let bundleID: String
    let displayName: String
    let category: PasteCompatibilityCategory

    var pasteDelay: Double { category.pasteDelay }
}

enum PasteCompatibilityRegistry {
    /// 远程桌面 / VDI / 虚拟机 / 游戏串流类应用的内置兼容性清单。
    /// 这类应用键盘事件经过网络或转发层，标准粘贴延迟下会丢字符。
    /// (Built-in compatibility list for remote desktop / VDI / virtual machine / game streaming apps.)
    /// (Their keyboard events pass through network or forwarding layers, so the standard paste delay can lose characters.)
    private static let builtin: [PasteCompatibilityProfile] = [
        // ── Apple 自带（远程桌面） (Apple built-in, remote desktop) ──
        .init(bundleID: "com.apple.ScreenSharing",           displayName: "Screen Sharing",          category: .remoteDesktop),
        .init(bundleID: "com.apple.RemoteDesktop",           displayName: "Apple Remote Desktop",    category: .remoteDesktop),

        // ── 国际主流远程控制 (major international remote-control apps) ──
        .init(bundleID: "com.microsoft.rdc.macos",           displayName: "Microsoft Remote Desktop", category: .remoteDesktop),
        .init(bundleID: "com.teamviewer.TeamViewer",         displayName: "TeamViewer",              category: .remoteDesktop),
        .init(bundleID: "com.teamviewer.TeamViewerQS",       displayName: "TeamViewer QuickSupport", category: .remoteDesktop),
        .init(bundleID: "com.philandro.anydesk",             displayName: "AnyDesk",                 category: .remoteDesktop),
        .init(bundleID: "com.realvnc.vncviewer",             displayName: "RealVNC Viewer",          category: .remoteDesktop),
        .init(bundleID: "com.p5sys.jump.mac.viewer",         displayName: "Jump Desktop",            category: .remoteDesktop),
        .init(bundleID: "com.splashtop.Splashtop-Business",  displayName: "Splashtop Business",      category: .remoteDesktop),
        .init(bundleID: "com.splashtop.SplashtopPersonal",   displayName: "Splashtop Personal",      category: .remoteDesktop),
        .init(bundleID: "com.citrix.receiver.icaviewer.mac", displayName: "Citrix Workspace",        category: .remoteDesktop),
        .init(bundleID: "com.nomachine.nxplayer",            displayName: "NoMachine",               category: .remoteDesktop),
        .init(bundleID: "com.carriez.rustdesk",              displayName: "RustDesk",                category: .remoteDesktop),
        .init(bundleID: "com.connectwise.ScreenConnect.Client", displayName: "ConnectWise ScreenConnect", category: .remoteDesktop),
        .init(bundleID: "com.zoho.assist",                   displayName: "Zoho Assist",             category: .remoteDesktop),
        .init(bundleID: "com.logmein.LogMeIn",               displayName: "LogMeIn",                 category: .remoteDesktop),
        .init(bundleID: "com.nicesoftware.dcv.viewer",       displayName: "NICE DCV",                category: .remoteDesktop),
        .init(bundleID: "com.royalapps.RoyalTSX",            displayName: "Royal TSX",               category: .remoteDesktop),
        .init(bundleID: "com.devolutions.remotedesktopmanager.free.mac", displayName: "Devolutions RDM", category: .remoteDesktop),

        // ── 企业 VDI / 云桌面（同远程桌面） (enterprise VDI / cloud desktops, same as remote desktop) ──
        .init(bundleID: "com.vmware.horizon.v4.viewclient",  displayName: "VMware Horizon Client",   category: .remoteDesktop),
        .init(bundleID: "com.amazon.workspaces",             displayName: "Amazon WorkSpaces",       category: .remoteDesktop),

        // ── 国内主流远控 (major China remote-control apps) ──
        .init(bundleID: "com.oray.sunlogin.SunloginClient",  displayName: "向日葵 Sunlogin",          category: .remoteDesktop),
        .init(bundleID: "com.todesk.todeskformac",           displayName: "ToDesk",                  category: .remoteDesktop),
        .init(bundleID: "com.netease.uurd",                  displayName: "网易 UU 远程",             category: .remoteDesktop),
        .init(bundleID: "com.rayvision.raylink",             displayName: "RayLink 瑞云",             category: .remoteDesktop),
        .init(bundleID: "com.gotohttp.gotohttp",             displayName: "GotoHTTP",                category: .remoteDesktop),

        // ── 本地虚拟机 (local virtual machines) ──
        .init(bundleID: "com.parallels.desktop.console",     displayName: "Parallels Desktop",       category: .virtualMachine),
        .init(bundleID: "com.parallels.client",              displayName: "Parallels Client",        category: .virtualMachine),
        .init(bundleID: "com.vmware.fusion",                 displayName: "VMware Fusion",           category: .virtualMachine),
        .init(bundleID: "com.utmapp.UTM",                    displayName: "UTM",                     category: .virtualMachine),
        .init(bundleID: "com.redhat.virt-viewer",            displayName: "virt-viewer / SPICE",     category: .virtualMachine),

        // ── 游戏串流 (game streaming) ──
        .init(bundleID: "com.parsec.www",                    displayName: "Parsec",                  category: .gameStreaming),
        .init(bundleID: "com.moonlight-stream.Moonlight",    displayName: "Moonlight",               category: .gameStreaming),
        .init(bundleID: "com.valvesoftware.steamlink",       displayName: "Steam Link",              category: .gameStreaming),
        .init(bundleID: "com.playstation.RemotePlay",        displayName: "PS Remote Play",          category: .gameStreaming),
    ]

    private static let bundleIDIndex: [String: PasteCompatibilityProfile] = {
        var dict: [String: PasteCompatibilityProfile] = [:]
        for p in builtin { dict[p.bundleID] = p }
        return dict
    }()

    /// 查找当前前台应用对应的兼容性配置。返回 nil 表示走默认粘贴行为。
    /// (Looks up the compatibility profile for the current frontmost app; nil means default paste behavior.)
    static func profile(forBundleID bundleID: String?) -> PasteCompatibilityProfile? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return bundleIDIndex[bundleID]
    }

    /// 查找当前前台应用对应的兼容性配置。返回 nil 表示走默认粘贴行为。
    /// (Looks up the compatibility profile for the current frontmost app; nil means default paste behavior.)
    static func profileForFrontmostApp() -> PasteCompatibilityProfile? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // 1. 先查内置白名单（远程桌面 / VM / 串流）。
        // (1. Built-in allow-list first — remote desktop / VM / streaming.)
        if let profile = profile(forBundleID: app.bundleIdentifier) {
            return profile
        }
        // 2. 白名单未命中时自动检测 Electron，命中则套用 .electron 类别的兜底延迟。
        // (2. Otherwise auto-detect Electron and apply the .electron category fallback delay.)
        guard isElectronApp(app) else { return nil }
        return PasteCompatibilityProfile(
            bundleID: app.bundleIdentifier ?? "",
            displayName: app.localizedName ?? "Electron",
            category: .electron
        )
    }

    // Electron 检测结果按 bundleID 缓存，避免每次粘贴都做文件系统检查（同一 App 只查一次）。
    // 仅在主线程（粘贴流程）访问，无需额外加锁。
    // (Cache Electron detection by bundleID so the filesystem is hit only once per app. Main-thread only.)
    private static var electronCheckCache: [String: Bool] = [:]

    /// 判断应用是否为 Electron / Chromium 套壳：检查 bundle 内是否存在 Electron Framework.framework。
    /// 这是 Electron 应用的硬性结构，比 Info.plist 特征更可靠。
    /// (Detect Electron / Chromium shells by checking for Electron Framework.framework inside the bundle —
    ///  a hard structural marker, more reliable than Info.plist heuristics.)
    static func isElectronApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else {
            return detectElectronFramework(app)
        }
        if let cached = electronCheckCache[bundleID] {
            return cached
        }
        let result = detectElectronFramework(app)
        electronCheckCache[bundleID] = result
        return result
    }

    private static func detectElectronFramework(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
