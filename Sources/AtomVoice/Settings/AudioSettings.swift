import Foundation

final class AudioSettings {
    private let backend: SettingsBackend

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var appleLiveInsertionEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.appleLiveInsertionEnabled, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.appleLiveInsertionEnabled) }
    }

    var silenceAutoStopEnabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.silenceAutoStopEnabled, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.silenceAutoStopEnabled) }
    }

    var silenceDuration: Double {
        get { backend.double(forKey: AppSettings.Keys.silenceDuration, default: AppSettings.defaultSilenceDuration) }
        set { backend.set(newValue, forKey: AppSettings.Keys.silenceDuration) }
    }

    var silenceThreshold: Double {
        get { backend.double(forKey: AppSettings.Keys.silenceThreshold, default: -40.0) }
        set { backend.set(newValue, forKey: AppSettings.Keys.silenceThreshold) }
    }

    var lowerVolumeOnRecording: Bool {
        get { backend.bool(forKey: AppSettings.Keys.lowerVolumeOnRecording, default: true) }
        set { backend.set(newValue, forKey: AppSettings.Keys.lowerVolumeOnRecording) }
    }

    var audioInputDeviceUID: String {
        get { backend.string(forKey: AppSettings.Keys.audioInputDeviceUID, default: "") }
        set { backend.set(newValue, forKey: AppSettings.Keys.audioInputDeviceUID) }
    }

    var pasteDelay: Double {
        get {
            let value = backend.double(forKey: AppSettings.Keys.pasteDelay, default: AppSettings.defaultPasteDelay)
            return value > 0 ? value : AppSettings.defaultPasteDelay
        }
        set { backend.set(newValue, forKey: AppSettings.Keys.pasteDelay) }
    }

    var tapModeManualStop: Bool {
        get { backend.bool(forKey: AppSettings.Keys.tapModeManualStop, default: false) }
        set { backend.set(newValue, forKey: AppSettings.Keys.tapModeManualStop) }
    }
}
