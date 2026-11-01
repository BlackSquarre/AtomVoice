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
    var hasChanges: Bool { get }
    func refreshStatus()
    func refresh()
    func save() -> ASRSettingsTabSaveOutcome
}

extension ASRSettingsTab {
    func refreshStatus() {}
}

/// 统一全窗提交范围；异步模型安装保留窗口，已保存页不重复写入。
enum ASRSettingsCommitter {
    static func save(_ pages: [ASRSettingsTab]) -> ASRSettingsTabSaveOutcome {
        var deferred = false
        for page in pages where page.hasChanges {
            switch page.save() {
            case .saved: break
            case .deferred: deferred = true
            case .failed(let message, let color): return .failed(message: message, color: color)
            }
        }
        return deferred ? .deferred : .saved
    }
}
