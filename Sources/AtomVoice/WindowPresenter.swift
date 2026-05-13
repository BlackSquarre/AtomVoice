import Cocoa

protocol WindowPresenting: AnyObject {
    func bringToFront(_ window: NSWindow)
    func bringToFrontInCurrentSpace(_ window: NSWindow)
    func resetActivationIfNeeded(closing: NSWindow?)
}

protocol AlertPresenting: AnyObject {
    @discardableResult
    func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse
}

final class WindowPresenter: WindowPresenting {
    static let shared = WindowPresenter()

    private init() {}

    /// 在 LSUIElement=true 的菜单栏应用里，先把窗口移动到当前 Space，
    /// 再显示和激活，避免在全屏 app 中打开窗口时跳回桌面。
    /// (In a LSUIElement=true menu bar app, move the window to the current Space first,
    /// then show and activate it, to avoid jumping back to the desktop when opening from a fullscreen app.)
    func bringToFront(_ window: NSWindow) {
        bringToFront(window, transient: false)
    }

    /// 从状态栏菜单打开的辅助窗口应留在当前 Space，包括其他 app 的全屏 Space。
    /// (Auxiliary windows opened from the status bar menu should stay in the current Space, including fullscreen Spaces of other apps.)
    func bringToFrontInCurrentSpace(_ window: NSWindow) {
        bringToFront(window, transient: true)
    }

    private func bringToFront(_ window: NSWindow, transient: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        var behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if transient { behavior.insert(.transient) }
        window.collectionBehavior.formUnion(behavior)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 菜单收起后一帧再确认一次，避免状态栏菜单焦点覆盖窗口焦点。
        // (Re-confirm one frame after menu dismisses, to prevent status bar menu focus from overriding window focus.)
        DispatchQueue.main.async {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 窗口关闭时调用：若已无其他普通窗口可见，恢复 accessory 策略。
    /// (Called when a window closes: if no other regular windows are visible, restore accessory activation policy.)
    func resetActivationIfNeeded(closing: NSWindow? = nil) {
        let hasOther = NSApp.windows.contains { window in
            if let closing, window === closing { return false }
            return window.isVisible && window.styleMask.contains(.titled)
        }
        if !hasOther { NSApp.setActivationPolicy(.accessory) }
    }
}

final class AlertPresenter: AlertPresenting {
    static let shared = AlertPresenter(windowPresenter: WindowPresenter.shared)

    private let windowPresenter: WindowPresenting

    private init(windowPresenter: WindowPresenting) {
        self.windowPresenter = windowPresenter
    }

    @discardableResult
    func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary, .transient])
        let response = alert.runModal()
        windowPresenter.resetActivationIfNeeded(closing: nil)
        return response
    }
}
