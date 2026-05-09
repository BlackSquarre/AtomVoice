import Foundation

struct AppLanguageOption {
    let code: String
    let displayName: String
}

struct LLMConnectionSettings {
    var baseURL: String
    var apiKey: String
    var model: String
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    enum Keys {
        static let selectedLanguage = "selectedLanguage"
        static let recognitionEngine = "recognitionEngine"
        static let appleLiveInsertionEnabled = "appleLiveInsertionEnabled"
        static let llmEnabled = "llmEnabled"
        static let llmAPIBaseURL = "llmAPIBaseURL"
        static let llmAPIKey = "llmAPIKey"
        static let llmModel = "llmModel"
        static let llmSystemPrompt = "llmSystemPrompt"
        static let llmProviders = "llmProviders"
        static let llmResultDelay = "llmResultDelay"
        static let autoPunctuationEnabled = "autoPunctuationEnabled"
        static let appleOnDeviceRecognitionEnabled = "appleOnDeviceRecognitionEnabled"
        static let animationStyle = "animationStyle"
        static let animationSpeed = "animationSpeed"
        static let silenceAutoStopEnabled = "silenceAutoStopEnabled"
        static let silenceDuration = "silenceDuration"
        static let silenceThreshold = "silenceThreshold"
        static let steadyNoiseSensitivity = "steadyNoiseSensitivity"
        static let triggerKeyCode = "triggerKeyCode"
        static let lowerVolumeOnRecording = "lowerVolumeOnRecording"
        static let audioInputDeviceUID = "audioInputDeviceUID"
        static let includeBetaUpdates = "includeBetaUpdates"
        static let sherpaAutoUnloadEnabled = "sherpaAutoUnloadEnabled"
        static let sherpaAutoUnloadIdleMinutes = "sherpaAutoUnloadIdleMinutes"
        static let sherpaProvider = "sherpaProvider"
        static let sherpaModelPresetID = "sherpaModelPresetID"
        static let doubaoASREndpoint = "doubaoASREndpoint"
        static let doubaoASRResourceID = "doubaoASRResourceID"
        static let doubaoASREnableITN = "doubaoASREnableITN"
        static let doubaoASREnableDDC = "doubaoASREnableDDC"
        static let doubaoASREnableNonstream = "doubaoASREnableNonstream"
        static let doubaoASRPrivacyAccepted = "doubaoASRPrivacyAccepted"
        static let doubaoASRLowLatencyDefaultApplied = "doubaoASRLowLatencyDefaultApplied"
    }

    static let defaultLanguageCode = "zh-CN"
    static let defaultLLMBaseURL = "https://api.openai.com/v1"
    static let defaultLLMModel = "gpt-4o-mini"
    static let defaultAnimationStyle = "dynamicIsland"
    static let defaultAnimationSpeed = "medium"
    static let defaultSherpaProvider = "cpu"
    static let defaultTriggerKeyCode: UInt16 = 63
    static let sherpaAutoUnloadMinuteOptions = [5, 10, 15, 30, 60]

    static let appLanguageOptions: [AppLanguageOption] = [
        AppLanguageOption(code: "en-US", displayName: "English"),
        AppLanguageOption(code: "zh-CN", displayName: "简体中文"),
        AppLanguageOption(code: "zh-TW", displayName: "繁體中文"),
        AppLanguageOption(code: "ja-JP", displayName: "日本語"),
        AppLanguageOption(code: "ko-KR", displayName: "한국어"),
        AppLanguageOption(code: "es-ES", displayName: "Español"),
        AppLanguageOption(code: "fr-FR", displayName: "Français"),
        AppLanguageOption(code: "de-DE", displayName: "Deutsch"),
    ]

    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.selectedLanguage: defaultLanguageCode,
            Keys.recognitionEngine: ASREngineRegistry.appleCode,
            Keys.appleLiveInsertionEnabled: false,
            Keys.llmEnabled: false,
            Keys.llmAPIBaseURL: defaultLLMBaseURL,
            Keys.llmModel: defaultLLMModel,
            Keys.autoPunctuationEnabled: true,
            Keys.appleOnDeviceRecognitionEnabled: false,
            Keys.llmResultDelay: 0.3,
            Keys.animationStyle: defaultAnimationStyle,
            Keys.animationSpeed: defaultAnimationSpeed,
            Keys.silenceAutoStopEnabled: false,
            Keys.silenceDuration: 2.0,
            Keys.silenceThreshold: -40.0,
            Keys.steadyNoiseSensitivity: 1,
            Keys.triggerKeyCode: Int(defaultTriggerKeyCode),
            Keys.lowerVolumeOnRecording: false,
            Keys.includeBetaUpdates: false,
            Keys.sherpaAutoUnloadEnabled: true,
            Keys.sherpaAutoUnloadIdleMinutes: 15,
            Keys.sherpaProvider: defaultSherpaProvider,
            Keys.doubaoASREndpoint: VolcengineASRSettings.defaultEndpoint,
            Keys.doubaoASRResourceID: VolcengineASRSettings.defaultResourceID,
            Keys.doubaoASREnableITN: true,
            Keys.doubaoASREnableDDC: false,
            Keys.doubaoASREnableNonstream: false,
            Keys.doubaoASRPrivacyAccepted: false,
            OOBEWindowController.completionDefaultsKey: false,
        ])
    }

    static func displayName(forRecognitionLanguage code: String) -> String {
        switch code {
        case "bilingual":
            return loc("asrSettings.sherpa.lang.bilingual")
        default:
            return appLanguageOptions.first(where: { $0.code == code })?.displayName ?? code
        }
    }

    static var selectedLanguage: String {
        get { defaults.string(forKey: Keys.selectedLanguage) ?? defaultLanguageCode }
        set { defaults.set(newValue, forKey: Keys.selectedLanguage) }
    }

    static var recognitionEngine: String {
        get { defaults.string(forKey: Keys.recognitionEngine) ?? ASREngineRegistry.appleCode }
        set { defaults.set(newValue, forKey: Keys.recognitionEngine) }
    }

    static var normalizedRecognitionEngine: String {
        ASREngineRegistry.shared.normalizedCode(for: recognitionEngine)
    }

    static var appleLiveInsertionEnabled: Bool {
        get { defaults.bool(forKey: Keys.appleLiveInsertionEnabled) }
        set { defaults.set(newValue, forKey: Keys.appleLiveInsertionEnabled) }
    }

    static var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    static var llmAPIBaseURL: String {
        get { defaults.string(forKey: Keys.llmAPIBaseURL) ?? defaultLLMBaseURL }
        set { defaults.set(newValue, forKey: Keys.llmAPIBaseURL) }
    }

    static var llmAPIKey: String {
        get { defaults.string(forKey: Keys.llmAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.llmAPIKey) }
    }

    static var llmModel: String {
        get { defaults.string(forKey: Keys.llmModel) ?? defaultLLMModel }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }

    static var llmSystemPrompt: String {
        get { defaults.string(forKey: Keys.llmSystemPrompt) ?? "" }
        set { defaults.set(newValue, forKey: Keys.llmSystemPrompt) }
    }

    static var llmResultDelay: Double {
        get { defaults.double(forKey: Keys.llmResultDelay) }
        set { defaults.set(newValue, forKey: Keys.llmResultDelay) }
    }

    static var llmConnection: LLMConnectionSettings {
        get {
            LLMConnectionSettings(
                baseURL: llmAPIBaseURL,
                apiKey: llmAPIKey,
                model: llmModel
            )
        }
        set {
            llmAPIBaseURL = newValue.baseURL
            llmAPIKey = newValue.apiKey
            llmModel = newValue.model
        }
    }

    static var autoPunctuationEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoPunctuationEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoPunctuationEnabled) }
    }

    static var appleOnDeviceRecognitionEnabled: Bool {
        get { defaults.bool(forKey: Keys.appleOnDeviceRecognitionEnabled) }
        set { defaults.set(newValue, forKey: Keys.appleOnDeviceRecognitionEnabled) }
    }

    static var animationStyle: String {
        get { defaults.string(forKey: Keys.animationStyle) ?? defaultAnimationStyle }
        set { defaults.set(newValue, forKey: Keys.animationStyle) }
    }

    static var animationSpeed: String {
        get { defaults.string(forKey: Keys.animationSpeed) ?? defaultAnimationSpeed }
        set { defaults.set(newValue, forKey: Keys.animationSpeed) }
    }

    static var silenceAutoStopEnabled: Bool {
        get { defaults.bool(forKey: Keys.silenceAutoStopEnabled) }
        set { defaults.set(newValue, forKey: Keys.silenceAutoStopEnabled) }
    }

    static var silenceDuration: Double {
        get { defaults.double(forKey: Keys.silenceDuration) }
        set { defaults.set(newValue, forKey: Keys.silenceDuration) }
    }

    static var silenceThreshold: Double {
        get { defaults.double(forKey: Keys.silenceThreshold) }
        set { defaults.set(newValue, forKey: Keys.silenceThreshold) }
    }

    static var steadyNoiseSensitivity: Int {
        get { defaults.integer(forKey: Keys.steadyNoiseSensitivity) }
        set { defaults.set(newValue, forKey: Keys.steadyNoiseSensitivity) }
    }

    static var triggerKeyCode: UInt16 {
        get { UInt16(defaults.integer(forKey: Keys.triggerKeyCode)) }
        set { defaults.set(Int(newValue), forKey: Keys.triggerKeyCode) }
    }

    static var lowerVolumeOnRecording: Bool {
        get { defaults.bool(forKey: Keys.lowerVolumeOnRecording) }
        set { defaults.set(newValue, forKey: Keys.lowerVolumeOnRecording) }
    }

    static var audioInputDeviceUID: String {
        get { defaults.string(forKey: Keys.audioInputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.audioInputDeviceUID) }
    }

    static var includeBetaUpdates: Bool {
        get { defaults.bool(forKey: Keys.includeBetaUpdates) }
        set { defaults.set(newValue, forKey: Keys.includeBetaUpdates) }
    }

    static var sherpaAutoUnloadEnabled: Bool {
        get { defaults.bool(forKey: Keys.sherpaAutoUnloadEnabled) }
        set { defaults.set(newValue, forKey: Keys.sherpaAutoUnloadEnabled) }
    }

    static var sherpaAutoUnloadIdleMinutes: Int {
        get { max(1, defaults.integer(forKey: Keys.sherpaAutoUnloadIdleMinutes)) }
        set { defaults.set(max(1, newValue), forKey: Keys.sherpaAutoUnloadIdleMinutes) }
    }

    static var sherpaProvider: String {
        get { defaults.string(forKey: Keys.sherpaProvider) ?? defaultSherpaProvider }
        set { defaults.set(newValue, forKey: Keys.sherpaProvider) }
    }

    static var sherpaModelPresetID: String {
        get { defaults.string(forKey: Keys.sherpaModelPresetID) ?? SherpaModelPreset.defaultModelID }
        set { defaults.set(newValue, forKey: Keys.sherpaModelPresetID) }
    }

    static var sherpaRecognitionLanguage: String {
        get { SherpaModelPreset.recognitionLanguage }
        set { defaults.set(newValue, forKey: SherpaModelPreset.recognitionLanguageKey) }
    }

    static var doubaoASRPrivacyAccepted: Bool {
        get { defaults.bool(forKey: Keys.doubaoASRPrivacyAccepted) }
        set { defaults.set(newValue, forKey: Keys.doubaoASRPrivacyAccepted) }
    }

    static var doubaoASRLowLatencyDefaultApplied: Bool {
        get { defaults.bool(forKey: Keys.doubaoASRLowLatencyDefaultApplied) }
        set { defaults.set(newValue, forKey: Keys.doubaoASRLowLatencyDefaultApplied) }
    }

    static var hasCompletedOOBE: Bool {
        get { defaults.bool(forKey: OOBEWindowController.completionDefaultsKey) }
        set { defaults.set(newValue, forKey: OOBEWindowController.completionDefaultsKey) }
    }
}
