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

    /// 该类别下统一使用的粘贴延迟（秒），会与全局 AppSettings.pasteDelay 取较大值。
    var pasteDelay: Double {
        switch self {
        case .virtualMachine: return 0.35
        case .remoteDesktop:  return 0.40
        case .gameStreaming:  return 0.50
        }
    }
}

/// 针对特定应用的粘贴兼容性条目。
struct PasteCompatibilityProfile {
    let bundleID: String
    let displayName: String
    let category: PasteCompatibilityCategory

    var pasteDelay: Double { category.pasteDelay }
}

enum PasteCompatibilityRegistry {
    /// 远程桌面 / VDI / 虚拟机 / 游戏串流类应用的内置兼容性清单。
    /// 这类应用键盘事件经过网络或转发层，标准粘贴延迟下会丢字符。
    private static let builtin: [PasteCompatibilityProfile] = [
        // ── Apple 自带（远程桌面） ──
        .init(bundleID: "com.apple.ScreenSharing",           displayName: "Screen Sharing",          category: .remoteDesktop),
        .init(bundleID: "com.apple.RemoteDesktop",           displayName: "Apple Remote Desktop",    category: .remoteDesktop),

        // ── 国际主流远程控制 ──
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

        // ── 企业 VDI / 云桌面（同远程桌面） ──
        .init(bundleID: "com.vmware.horizon.v4.viewclient",  displayName: "VMware Horizon Client",   category: .remoteDesktop),
        .init(bundleID: "com.amazon.workspaces",             displayName: "Amazon WorkSpaces",       category: .remoteDesktop),

        // ── 国内主流远控 ──
        .init(bundleID: "com.oray.sunlogin.SunloginClient",  displayName: "向日葵 Sunlogin",          category: .remoteDesktop),
        .init(bundleID: "com.todesk.todeskformac",           displayName: "ToDesk",                  category: .remoteDesktop),
        .init(bundleID: "com.netease.uurd",                  displayName: "网易 UU 远程",             category: .remoteDesktop),
        .init(bundleID: "com.rayvision.raylink",             displayName: "RayLink 瑞云",             category: .remoteDesktop),
        .init(bundleID: "com.gotohttp.gotohttp",             displayName: "GotoHTTP",                category: .remoteDesktop),

        // ── 本地虚拟机 ──
        .init(bundleID: "com.parallels.desktop.console",     displayName: "Parallels Desktop",       category: .virtualMachine),
        .init(bundleID: "com.parallels.client",              displayName: "Parallels Client",        category: .virtualMachine),
        .init(bundleID: "com.vmware.fusion",                 displayName: "VMware Fusion",           category: .virtualMachine),
        .init(bundleID: "com.utmapp.UTM",                    displayName: "UTM",                     category: .virtualMachine),
        .init(bundleID: "com.redhat.virt-viewer",            displayName: "virt-viewer / SPICE",     category: .virtualMachine),

        // ── 游戏串流 ──
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
    static func profileForFrontmostApp() -> PasteCompatibilityProfile? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return nil
        }
        return bundleIDIndex[bundleID]
    }
}
