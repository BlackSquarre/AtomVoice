import Cocoa

/// 菜单窗口路由：按需懒加载窗口控制器，窗口关闭后释放对应实例以回收内存。
/// (Menu window router: lazy-create controllers on demand, release them when the window closes to reclaim memory.)
final class MenuWindowRouter {
    private let llmRefiner: LLMRefiner
    private var settingsWindow: SettingsWindowController?
    private var doubaoSettingsWindow: DoubaoSettingsWindowController?
    private var asrSettingsWindow: ASRSettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var permissionsWindow: PermissionsWindowController?

    init(llmRefiner: LLMRefiner) {
        self.llmRefiner = llmRefiner
    }

    func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(llmRefiner: llmRefiner)
            // 关闭后下个 runloop 释放，避免在 windowWillClose 回调途中销毁 delegate
            // (Release on next runloop to avoid tearing down the delegate mid-callback)
            controller.onClose = { [weak self] in
                DispatchQueue.main.async { self?.settingsWindow = nil }
            }
            settingsWindow = controller
        }
        settingsWindow?.showWindow()
    }

    func openDoubaoSettings() {
        if doubaoSettingsWindow == nil {
            let controller = DoubaoSettingsWindowController()
            controller.onClose = { [weak self] in
                DispatchQueue.main.async { self?.doubaoSettingsWindow = nil }
            }
            doubaoSettingsWindow = controller
        }
        doubaoSettingsWindow?.showWindow()
    }

    func openASRSettings() {
        if asrSettingsWindow == nil {
            let controller = ASRSettingsWindowController()
            controller.onClose = { [weak self] in
                DispatchQueue.main.async { self?.asrSettingsWindow = nil }
            }
            asrSettingsWindow = controller
        }
        asrSettingsWindow?.showWindow()
    }

    func openAbout() {
        if aboutWindow == nil {
            let controller = AboutWindowController()
            controller.onClose = { [weak self] in
                DispatchQueue.main.async { self?.aboutWindow = nil }
            }
            aboutWindow = controller
        }
        aboutWindow?.showWindow()
    }

    func openPermissions() {
        if permissionsWindow == nil {
            let controller = PermissionsWindowController()
            controller.onClose = { [weak self] in
                DispatchQueue.main.async { self?.permissionsWindow = nil }
            }
            permissionsWindow = controller
        }
        permissionsWindow?.showWindow()
    }
}
