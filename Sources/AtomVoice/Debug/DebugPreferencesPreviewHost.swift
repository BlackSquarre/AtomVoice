#if DEBUG_BUILD
import Cocoa

/// 只呈现真实设置视图的内存副本；不连接输入监听、钥匙串、权限或网络。
final class DebugPreferencesPreviewHost: NSObject {
    private let controller = UnifiedSettingsWindowController(
        llmRefiner: LLMRefiner(), sherpaDownloadReporter: nil, allowsSideEffects: false
    )

    func show(page: String) {
        MainMenuInstaller.install()
        MainMenuInstaller.openSettings = { [weak self] in self?.controller.showWindow() }
        MainMenuInstaller.openAbout = { [weak self] in self?.controller.showWindow(page: .about) }
        installMenuFixture()
        controller.showSnapshot(page: page)
    }

    /// 仅在安全预览中呈现生产菜单排版，选择项不连接任何真实设置。
    private func installMenuFixture() {
        let title = loc("preferences.debug.tools")
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        // 与安全预览内存 store 的初始值一致，不读取真实触发键或输入模式。
        let selectedTrigger = TriggerKeyOption.option(for: 61)
        let isTapMode = false
        for heading in [loc(isTapMode ? "menu.tapKey" : "menu.holdKey", loc(selectedTrigger.symbolKey)),
                        loc("menu.startVoiceInput")] {
            let hint = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        let trigger = NSMenuItem(title: loc("menu.triggerKey"), action: nil, keyEquivalent: "")
        let triggerChoices = NSMenu()
        for option in TriggerKeyOption.all {
            let choice = NSMenuItem(title: loc(option.locKey), action: #selector(ignoreFixtureSelection(_:)), keyEquivalent: "")
            choice.target = self
            choice.state = option.keyCode == selectedTrigger.keyCode ? .on : .off
            triggerChoices.addItem(choice)
        }
        trigger.submenu = triggerChoices
        menu.addItem(trigger)

        let engine = NSMenuItem(title: loc("menu.recognitionEngine"), action: nil, keyEquivalent: "")
        let engineChoices = NSMenu()
        for descriptor in ASREngineRegistry.shared.descriptors {
            let choice = NSMenuItem(title: loc(descriptor.displayNameKey), action: #selector(ignoreFixtureSelection(_:)), keyEquivalent: "")
            choice.target = self
            choice.state = descriptor.code == ASREngineRegistry.appleCode ? .on : .off
            engineChoices.addItem(choice)
        }
        engine.submenu = engineChoices
        menu.addItem(engine)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: loc("preferences.settingsCommand"), action: #selector(showFixtureSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: loc("menu.app.quit", loc("app.title")), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        top.submenu = menu
        NSApp.mainMenu?.addItem(top)
    }

    @objc private func ignoreFixtureSelection(_ sender: NSMenuItem) {}
    @objc private func showFixtureSettings(_ sender: NSMenuItem) { controller.showWindow() }
}
#endif
