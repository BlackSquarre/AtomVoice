import Cocoa

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
            settingsWindow = SettingsWindowController(llmRefiner: llmRefiner)
        }
        settingsWindow?.showWindow()
    }

    func openDoubaoSettings() {
        if doubaoSettingsWindow == nil {
            doubaoSettingsWindow = DoubaoSettingsWindowController()
        }
        doubaoSettingsWindow?.showWindow()
    }

    func openASRSettings() {
        if asrSettingsWindow == nil {
            asrSettingsWindow = ASRSettingsWindowController()
        }
        asrSettingsWindow?.showWindow()
    }

    func openAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController()
        }
        aboutWindow?.showWindow()
    }

    func openPermissions() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.showWindow()
    }
}
