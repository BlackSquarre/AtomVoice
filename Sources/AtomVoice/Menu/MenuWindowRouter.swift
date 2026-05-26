import Cocoa

/// 菜单窗口路由：按需懒加载窗口控制器，窗口关闭后释放对应实例以回收内存。
///
/// 所有 open* 方法遵守同一份模板：
///   1. 槽位为空 → 用工厂构造控制器；
///   2. 绑定 onClose，下一轮 runloop 把槽位置 nil（避免在 windowWillClose 中销毁 delegate）；
///   3. showWindow()。
/// 不抽成共享辅助函数——6 个调用点就在文件里前后排列，模式扫一眼就能看清。
///
/// (Menu window router: lazy-create controllers on demand, release on close.
///  All open* methods follow the same template; kept inline for at-a-glance consistency.)
final class MenuWindowRouter {
    private let llmRefiner: LLMRefiner
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    private var settingsWindow: SettingsWindowController?
    private var doubaoSettingsWindow: DoubaoSettingsWindowController?
    private var asrSettingsWindow: ASRSettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var permissionsWindow: PermissionsWindowController?
    private var oobeWindow: OOBEWindowController?

    init(llmRefiner: LLMRefiner, sherpaDownloadReporter: SherpaDownloadReporting) {
        self.llmRefiner = llmRefiner
        self.sherpaDownloadReporter = sherpaDownloadReporter
    }

    func openSettings() {
        if settingsWindow == nil {
            let c = SettingsWindowController(llmRefiner: llmRefiner)
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.settingsWindow = nil } }
            settingsWindow = c
        }
        settingsWindow?.showWindow()
    }

    func openDoubaoSettings() {
        if doubaoSettingsWindow == nil {
            let c = DoubaoSettingsWindowController()
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.doubaoSettingsWindow = nil } }
            doubaoSettingsWindow = c
        }
        doubaoSettingsWindow?.showWindow()
    }

    func openASRSettings() {
        if asrSettingsWindow == nil {
            let c = ASRSettingsWindowController(sherpaDownloadReporter: sherpaDownloadReporter)
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.asrSettingsWindow = nil } }
            asrSettingsWindow = c
        }
        asrSettingsWindow?.showWindow()
    }

    #if DEBUG_BUILD
    func openASRSettingsSnapshot(tabIdentifier: String) {
        if asrSettingsWindow == nil {
            let c = ASRSettingsWindowController(sherpaDownloadReporter: sherpaDownloadReporter)
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.asrSettingsWindow = nil } }
            asrSettingsWindow = c
        }
        asrSettingsWindow?.showWindowForSnapshot(tabIdentifier: tabIdentifier)
    }
    #endif

    func openAbout() {
        if aboutWindow == nil {
            let c = AboutWindowController()
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.aboutWindow = nil } }
            aboutWindow = c
        }
        aboutWindow?.showWindow()
    }

    func openPermissions() {
        if permissionsWindow == nil {
            let c = PermissionsWindowController()
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.permissionsWindow = nil } }
            permissionsWindow = c
        }
        permissionsWindow?.showWindow()
    }

    /// OOBE 的业务回调（onFinish）只在创建时由调用方注入一次。
    /// (OOBE business callbacks injected once on creation via `configure`.)
    func openOOBE(configure: (OOBEWindowController) -> Void) {
        openOOBE(initialStep: nil, configure: configure)
    }

    #if DEBUG_BUILD
    func openOOBESnapshot(step: Int, configure: (OOBEWindowController) -> Void) {
        openOOBE(initialStep: step, configure: configure)
    }
    #endif

    private func openOOBE(initialStep: Int?, configure: (OOBEWindowController) -> Void) {
        if oobeWindow == nil {
            let c = OOBEWindowController()
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.oobeWindow = nil } }
            configure(c)
            oobeWindow = c
        }
        #if DEBUG_BUILD
        if let initialStep {
            oobeWindow?.showWindowForSnapshot(step: initialStep)
        } else {
            oobeWindow?.showWindow()
        }
        #else
        oobeWindow?.showWindow()
        #endif
    }
}
