import Foundation

final class InterfaceSettings {
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var animationStyle: String {
        get { backend.string(forKey: AppSettings.Keys.animationStyle, default: AppSettings.defaultAnimationStyle) }
        set { backend.set(newValue, forKey: AppSettings.Keys.animationStyle) }
    }

    var animationSpeed: String {
        get { backend.string(forKey: AppSettings.Keys.animationSpeed, default: AppSettings.defaultAnimationSpeed) }
        set { backend.set(newValue, forKey: AppSettings.Keys.animationSpeed) }
    }

    var triggerKeyCode: UInt16 {
        get { UInt16(backend.integer(forKey: AppSettings.Keys.triggerKeyCode, default: Int(AppSettings.defaultTriggerKeyCode))) }
        set { backend.set(Int(newValue), forKey: AppSettings.Keys.triggerKeyCode) }
    }

    var headphoneControlEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.headphoneControlEnabled, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.headphoneControlEnabled) }
    }
}
