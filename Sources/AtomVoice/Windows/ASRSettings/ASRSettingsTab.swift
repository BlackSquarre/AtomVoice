import Cocoa

enum ASRSettingsTabSaveOutcome {
    case saved
    case failed(message: String, color: NSColor)
    case deferred
}

protocol ASRSettingsTab: AnyObject {
    var identifier: String { get }
    var label: String { get }
    func makeView() -> NSView
    func refresh()
    func save() -> ASRSettingsTabSaveOutcome
}
