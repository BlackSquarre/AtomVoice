import Foundation

/// 菜单/窗口需要回拨 AppDelegate 的少量动作；通过协议显式注入，避免
/// `(NSApp.delegate as? AppDelegate)?.xxx()` 这种隐式的全局查找。
/// (Small set of actions menu/window controllers occasionally need to ask AppDelegate
/// to perform; passed in via this protocol to avoid implicit `NSApp.delegate as? AppDelegate`
/// lookups.)
protocol AppHostActions: AnyObject {
    /// 重新展示 OOBE 窗口（菜单里"重新走一遍引导"使用）。
    /// (Re-present the OOBE window; used by the "run onboarding again" menu item.)
    func showOOBE()

    /// 切换耳机线控启用状态（菜单里的勾选项使用）。
    /// (Toggle headphone remote control; used by the headphone-control menu item.)
    func setHeadphoneControlEnabled(_ enabled: Bool)
}
