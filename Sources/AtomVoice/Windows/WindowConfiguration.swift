import Cocoa

enum WindowConfiguration {
    static func configureKeyViewLoop(_ window: NSWindow, identifier: String? = nil) {
        if let identifier {
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        window.autorecalculatesKeyViewLoop = true
        window.recalculateKeyViewLoop()
    }

    @discardableResult
    static func configureRestorableSettingsWindow(_ window: NSWindow, identifier: String) -> Bool {
        configureKeyViewLoop(window, identifier: identifier)
        let autosaveName = NSWindow.FrameAutosaveName(identifier)
        let restored = window.setFrameUsingName(autosaveName, force: true)
        window.setFrameAutosaveName(autosaveName)
        return restored
    }

    static func configureSheet(_ window: NSWindow, identifier: String? = nil) {
        configureKeyViewLoop(window, identifier: identifier)
        window.preventsApplicationTerminationWhenModal = false
    }
}
