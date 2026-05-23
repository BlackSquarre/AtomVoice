import Foundation

final class OOBESettings {
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var hasCompletedOOBE: Bool {
        get { backend.bool(forKey: OOBEWindowController.completionDefaultsKey, default: false) }
        set { backend.set(newValue, forKey: OOBEWindowController.completionDefaultsKey) }
    }

    var headphoneControlAlertShown: Bool {
        get { backend.bool(forKey: AppSettings.Keys.headphoneControlAlertShown, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.headphoneControlAlertShown) }
    }
}
