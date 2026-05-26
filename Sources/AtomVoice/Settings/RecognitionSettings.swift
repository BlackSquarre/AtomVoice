import Foundation

final class RecognitionSettings {
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var selectedLanguage: String {
        get { backend.string(forKey: AppSettings.Keys.selectedLanguage, default: AppSettings.systemDefaultLanguage) }
        set { backend.set(newValue, forKey: AppSettings.Keys.selectedLanguage) }
    }

    var engine: String {
        get { backend.string(forKey: AppSettings.Keys.recognitionEngine, default: ASREngineRegistry.appleCode) }
        set { setRecognitionTrackedString(newValue, key: AppSettings.Keys.recognitionEngine, currentValue: { engine }) }
    }

    var normalizedEngine: String {
        ASREngineRegistry.shared.normalizedCode(for: engine)
    }

    var autoPunctuationEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.autoPunctuationEnabled, default: true) }
        set { backend.set(newValue, forKey: AppSettings.Keys.autoPunctuationEnabled) }
    }

    var appleOnDeviceRecognitionEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.appleOnDeviceRecognitionEnabled, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.appleOnDeviceRecognitionEnabled) }
    }

    var sherpaAutoUnloadEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.sherpaAutoUnloadEnabled, default: true) }
        set { backend.set(newValue, forKey: AppSettings.Keys.sherpaAutoUnloadEnabled) }
    }

    var sherpaAutoUnloadIdleMinutes: Int {
        get { max(1, backend.integer(forKey: AppSettings.Keys.sherpaAutoUnloadIdleMinutes, default: 15)) }
        set { backend.set(max(1, newValue), forKey: AppSettings.Keys.sherpaAutoUnloadIdleMinutes) }
    }

    var sherpaProvider: String {
        get { backend.string(forKey: AppSettings.Keys.sherpaProvider, default: AppSettings.defaultSherpaProvider) }
        set { setRecognitionTrackedString(newValue, key: AppSettings.Keys.sherpaProvider, currentValue: { sherpaProvider }) }
    }

    var sherpaModelPresetID: String {
        get { backend.string(forKey: AppSettings.Keys.sherpaModelPresetID, default: SherpaModelPreset.defaultModelID) }
        set { setRecognitionTrackedString(newValue, key: AppSettings.Keys.sherpaModelPresetID, currentValue: { sherpaModelPresetID }) }
    }

    var sherpaRecognitionLanguage: String {
        get { backend.string(forKey: AppSettings.Keys.sherpaRecognitionLanguage) ?? selectedLanguage }
        set {
            setRecognitionTrackedString(
                newValue,
                key: AppSettings.Keys.sherpaRecognitionLanguage,
                currentValue: { sherpaRecognitionLanguage }
            )
        }
    }

    var doubaoASRPrivacyAccepted: Bool {
        get { backend.bool(forKey: AppSettings.Keys.doubaoASRPrivacyAccepted, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.doubaoASRPrivacyAccepted) }
    }

    var doubaoASRLowLatencyDefaultApplied: Bool {
        get { backend.bool(forKey: AppSettings.Keys.doubaoASRLowLatencyDefaultApplied, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.doubaoASRLowLatencyDefaultApplied) }
    }

    private func setRecognitionTrackedString(
        _ value: String,
        key: String,
        currentValue: () -> String
    ) {
        let oldValue = currentValue()
        backend.set(value, forKey: key)
        let newValue = currentValue()
        guard oldValue != newValue else { return }
        NotificationCenter.default.post(
            name: AppSettings.recognitionEngineSettingsDidChangeNotification,
            object: backend.notificationObject,
            userInfo: [AppSettings.recognitionEngineSettingsChangedKey: key]
        )
    }
}
