import Foundation

final class UpdateSettings {
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var includeBetaUpdates: Bool {
        get { backend.bool(forKey: AppSettings.Keys.includeBetaUpdates, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.includeBetaUpdates) }
    }

    var updateToDebugBuilds: Bool {
        get { backend.bool(forKey: AppSettings.Keys.updateToDebugBuilds, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.updateToDebugBuilds) }
    }
}
