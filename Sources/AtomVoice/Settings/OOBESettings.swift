import Foundation

final class OOBESettings {
    static let completionDefaultsKey = "hasCompletedOOBE"
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var hasCompletedOOBE: Bool {
        get { backend.bool(forKey: Self.completionDefaultsKey, default: false) }
        set { backend.set(newValue, forKey: Self.completionDefaultsKey) }
    }

    var headphoneControlAlertShown: Bool {
        get { backend.bool(forKey: AppSettings.Keys.headphoneControlAlertShown, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.headphoneControlAlertShown) }
    }
}
