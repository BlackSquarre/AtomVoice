import Cocoa

/// 菜单窗口路由：统一设置控制器跨关闭缓存草稿，OOBE 保持独立生命周期。
final class MenuWindowRouter {
    private let llmRefiner: LLMRefiner
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    var onTriggerKeyChanged: ((UInt16) -> Void)?
    var onHeadphoneChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onSelectEngine: ((String) -> Void)?
    #if DEBUG_BUILD
    var makeDebugToolsMenu: (() -> NSMenu)?
    #endif
    private var unifiedWindow: UnifiedSettingsWindowController?
    private var asrSettingsWindow: ASRSettingsWindowController?
    private var oobeWindow: OOBEWindowController?

    init(llmRefiner: LLMRefiner, sherpaDownloadReporter: SherpaDownloadReporting) {
        self.llmRefiner = llmRefiner
        self.sherpaDownloadReporter = sherpaDownloadReporter
    }

    private func unifiedSettings() -> UnifiedSettingsWindowController {
        if let unifiedWindow { return unifiedWindow }
        let controller = UnifiedSettingsWindowController(llmRefiner: llmRefiner, sherpaDownloadReporter: sherpaDownloadReporter)
        controller.onTriggerChanged = { [weak self] in self?.onTriggerKeyChanged?($0) }
        controller.onHeadphoneChanged = { [weak self] in self?.onHeadphoneChanged?($0) }
        controller.onLanguageChanged = { [weak self] in self?.onLanguageChanged?() }
        controller.onSettingsChanged = { [weak self] in self?.onSettingsChanged?() }
        controller.onSelectEngine = { [weak self] in self?.onSelectEngine?($0) }
        #if DEBUG_BUILD
        controller.makeDebugToolsMenu = { [weak self] in self?.makeDebugToolsMenu?() ?? NSMenu() }
        #endif
        unifiedWindow = controller
        return controller
    }

    func openSettings() { unifiedSettings().showWindow() }
    func openDoubaoSettings() { unifiedSettings().showConnections(selecting: VolcengineASRSettings.engineCode) }
    func openASRSettings(selecting engineCode: String? = nil) {
        unifiedSettings().showConnections(selecting: engineCode ?? AppSettings.normalizedRecognitionEngine)
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

    func openAbout() { unifiedSettings().showWindow(page: .about) }
    func openPermissions() { unifiedSettings().showWindow(page: .permissions) }

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
