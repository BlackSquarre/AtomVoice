import AppKit

/// 系统跳转只共享打开与失败反馈；权限策略仍由 PermissionService 决定。
struct ExternalDestinationOpener {
    static let shared = ExternalDestinationOpener()
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var reportFailure: () -> Void = {
        let alert = NSAlert()
        alert.messageText = loc("external.openFailed")
        AlertPresenter.shared.runModalAlert(alert)
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard openURL(url) else { reportFailure(); return false }
        return true
    }

    @discardableResult
    func openSoundSettings() -> Bool {
        for value in ["x-apple.systempreferences:com.apple.Sound-Settings.extension",
                      "x-apple.systempreferences:com.apple.preference.sound"] {
            if let url = URL(string: value), openURL(url) { return true }
        }
        if let url = applicationURL("com.apple.systempreferences"), openURL(url) { return true }
        reportFailure()
        return false
    }
}
