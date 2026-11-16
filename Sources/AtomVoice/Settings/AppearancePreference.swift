import Cocoa

/// App 外观只有一个来源；窗口与胶囊继承它，不建立另一套主题偏好。
enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return loc("preferences.appearance.system")
        case .light: return loc("preferences.appearance.light")
        case .dark: return loc("preferences.appearance.dark")
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// nil 交还给系统；系统自动切换无需由 App 复制日夜定时逻辑。
    static func applyToApplication(_ preference: AppearancePreference? = nil) {
        performOnMain {
            guard let application = NSApp else { return }
            application.appearance = (preference ?? AppSettings.appearanceMode).appKitAppearance
        }
    }

    /// 新窗口沿 NSApp 继承外观，后续修改会同时作用于已打开的窗口。
    static func apply(to window: NSWindow) {
        performOnMain { [weak window] in
            applyToApplication()
            window?.appearance = nil
        }
    }

    private static func performOnMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }
}
