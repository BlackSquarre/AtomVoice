import Foundation

struct AppLanguageOption {
    let code: String
    let displayNameKey: String

    var displayName: String { loc(displayNameKey) }
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
        static let pasteDelay = "pasteDelay"
        static let tapModeManualStop = "tapModeManualStop"
        static let headphoneControlEnabled = "headphoneControlEnabled"
        static let headphoneControlAlertShown = "headphoneControlAlertShown"
    }

    static let defaultPasteDelay: Double = 0.25
    static let pasteDelayOptions: [Double] = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40]

    static let defaultLanguageCode = "zh-CN"
    static let defaultLLMBaseURL = "https://api.openai.com/v1"
    static let defaultLLMModel = "gpt-4o-mini"
    static let defaultAnimationStyle = "dynamicIsland"
    static let defaultAnimationSpeed = "medium"
    static let defaultSherpaProvider = "coreml"
    static let defaultTriggerKeyCode: UInt16 = 61
    static let sherpaAutoUnloadMinuteOptions = [5, 10, 15, 30, 60]

    static let appLanguageOptions: [AppLanguageOption] = [
        AppLanguageOption(code: "en-US", displayNameKey: "language.en-US"),
        AppLanguageOption(code: "zh-CN", displayNameKey: "language.zh-CN"),
        AppLanguageOption(code: "zh-TW", displayNameKey: "language.zh-TW"),
        AppLanguageOption(code: "ja-JP", displayNameKey: "language.ja-JP"),
        AppLanguageOption(code: "ko-KR", displayNameKey: "language.ko-KR"),
        AppLanguageOption(code: "es-ES", displayNameKey: "language.es-ES"),
        AppLanguageOption(code: "fr-FR", displayNameKey: "language.fr-FR"),
        AppLanguageOption(code: "de-DE", displayNameKey: "language.de-DE"),
    ]

    /// 根据系统语言推断初始识别语言，没匹配上回退到英文。
    /// (Infer initial recognition language from system locale; fall back to English if unsupported.)
    static var systemDefaultLanguage: String {
        let lang = Locale.current.language
        let code = lang.languageCode?.identifier ?? "en"
        let region = lang.region?.identifier ?? ""
        switch code {
        case "zh":
            return ["TW", "HK", "MO"].contains(region) ? "zh-TW" : "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        default:   return "en-US"
        }
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.selectedLanguage: systemDefaultLanguage,
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
            Keys.triggerKeyCode: Int(defaultTriggerKeyCode),
            Keys.lowerVolumeOnRecording: true,
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
            Keys.pasteDelay: defaultPasteDelay,
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
        get { defaults.string(forKey: Keys.selectedLanguage) ?? systemDefaultLanguage }
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

    /// 粘贴后等待目标 App 真正读取剪贴板的延迟，调过 0.15s→0.25s 修复 Electron。
    /// (Post-paste delay so the target app finishes reading the clipboard. Bumped from 0.15s to 0.25s for Electron.)
    static var pasteDelay: Double {
        get {
            let v = defaults.double(forKey: Keys.pasteDelay)
            return v > 0 ? v : defaultPasteDelay
        }
        set { defaults.set(newValue, forKey: Keys.pasteDelay) }
    }

    /// 单击说话模式下：true 表示禁用静音自动停止，必须再点一次触发键才结束。
    /// (Tap-to-talk mode: when true, silence auto-stop is disabled — only a 2nd trigger-key tap stops recording.)
    static var tapModeManualStop: Bool {
        get { defaults.bool(forKey: Keys.tapModeManualStop) }
        set { defaults.set(newValue, forKey: Keys.tapModeManualStop) }
    }

    /// 使用耳机线控按钮控制录音（单击/长按按当前输入模式匹配，双击回车）。
    /// (Use headphone remote button to control recording — single/long press matches input mode, double tap sends Return.)
    static var headphoneControlEnabled: Bool {
        get { defaults.bool(forKey: Keys.headphoneControlEnabled) }
        set { defaults.set(newValue, forKey: Keys.headphoneControlEnabled) }
    }

    static var headphoneControlAlertShown: Bool {
        get { defaults.bool(forKey: Keys.headphoneControlAlertShown) }
        set { defaults.set(newValue, forKey: Keys.headphoneControlAlertShown) }
    }

    static var hasCompletedOOBE: Bool {
        get { defaults.bool(forKey: OOBEWindowController.completionDefaultsKey) }
        set { defaults.set(newValue, forKey: OOBEWindowController.completionDefaultsKey) }
    }
}
