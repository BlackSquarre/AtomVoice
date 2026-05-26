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
    static let backend: SettingsBackend = UserDefaultsBackend(defaults: .standard)
    static let recognition = RecognitionSettings(backend: backend)
    static let llm = LLMSettings(backend: backend)
    static let audio = AudioSettings(backend: backend)
    static let oobe = OOBESettings(backend: backend)
    static let update = UpdateSettings(backend: backend)
    static let interface = InterfaceSettings(backend: backend)

    static let recognitionEngineSettingsDidChangeNotification = Notification.Name("AppSettings.recognitionEngineSettingsDidChange")
    static let recognitionEngineSettingsChangedKey = "key"

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
        static let updateToDebugBuilds = "updateToDebugBuilds"
        static let sherpaAutoUnloadEnabled = "sherpaAutoUnloadEnabled"
        static let sherpaAutoUnloadIdleMinutes = "sherpaAutoUnloadIdleMinutes"
        static let sherpaProvider = "sherpaProvider"
        static let sherpaModelPresetID = "sherpaModelPresetID"
        static let sherpaRecognitionLanguage = "sherpaRecognitionLanguage"
        static let textOutputSink = "textOutputSink"
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
    static let defaultSilenceDuration: Double = 3.0

    static let defaultLanguageCode = "zh-CN"
    static let defaultLLMBaseURL = "https://api.openai.com/v1"
    static let defaultLLMModel = "gpt-5.4-mini"
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
        backend.register(defaults: [
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
            Keys.silenceDuration: defaultSilenceDuration,
            Keys.silenceThreshold: -40.0,
            Keys.triggerKeyCode: Int(defaultTriggerKeyCode),
            Keys.lowerVolumeOnRecording: true,
            Keys.includeBetaUpdates: false,
            Keys.updateToDebugBuilds: false,
            Keys.sherpaAutoUnloadEnabled: true,
            Keys.sherpaAutoUnloadIdleMinutes: 15,
            Keys.sherpaProvider: defaultSherpaProvider,
            Keys.textOutputSink: TextOutputSinkRegistry.pasteCode,
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
        get { recognition.selectedLanguage }
        set { recognition.selectedLanguage = newValue }
    }

    static var recognitionEngine: String {
        get { recognition.engine }
        set { recognition.engine = newValue }
    }

    static var normalizedRecognitionEngine: String {
        recognition.normalizedEngine
    }

    static var appleLiveInsertionEnabled: Bool {
        get { audio.appleLiveInsertionEnabled }
        set { audio.appleLiveInsertionEnabled = newValue }
    }

    static var llmEnabled: Bool {
        get { llm.enabled }
        set { llm.enabled = newValue }
    }

    static var llmAPIBaseURL: String {
        get { llm.apiBaseURL }
        set { llm.apiBaseURL = newValue }
    }

    static var llmAPIKey: String {
        get { llm.apiKey }
        set { llm.apiKey = newValue }
    }

    static var llmModel: String {
        get { llm.model }
        set { llm.model = newValue }
    }

    static var llmSystemPrompt: String {
        get { llm.systemPrompt }
        set { llm.systemPrompt = newValue }
    }

    static var llmResultDelay: Double {
        get { llm.resultDelay }
        set { llm.resultDelay = newValue }
    }

    static var llmConnection: LLMConnectionSettings {
        get { llm.connection }
        set { llm.connection = newValue }
    }

    static var autoPunctuationEnabled: Bool {
        get { recognition.autoPunctuationEnabled }
        set { recognition.autoPunctuationEnabled = newValue }
    }

    static var appleOnDeviceRecognitionEnabled: Bool {
        get { recognition.appleOnDeviceRecognitionEnabled }
        set { recognition.appleOnDeviceRecognitionEnabled = newValue }
    }

    static var animationStyle: String {
        get { interface.animationStyle }
        set { interface.animationStyle = newValue }
    }

    static var animationSpeed: String {
        get { interface.animationSpeed }
        set { interface.animationSpeed = newValue }
    }

    static var silenceAutoStopEnabled: Bool {
        get { audio.silenceAutoStopEnabled }
        set { audio.silenceAutoStopEnabled = newValue }
    }

    static var silenceDuration: Double {
        get { audio.silenceDuration }
        set { audio.silenceDuration = newValue }
    }

    static var silenceThreshold: Double {
        get { audio.silenceThreshold }
        set { audio.silenceThreshold = newValue }
    }

    static var triggerKeyCode: UInt16 {
        get { interface.triggerKeyCode }
        set { interface.triggerKeyCode = newValue }
    }

    static var lowerVolumeOnRecording: Bool {
        get { audio.lowerVolumeOnRecording }
        set { audio.lowerVolumeOnRecording = newValue }
    }

    static var audioInputDeviceUID: String {
        get { audio.audioInputDeviceUID }
        set { audio.audioInputDeviceUID = newValue }
    }

    static var includeBetaUpdates: Bool {
        get { update.includeBetaUpdates }
        set { update.includeBetaUpdates = newValue }
    }

    static var updateToDebugBuilds: Bool {
        get { update.updateToDebugBuilds }
        set { update.updateToDebugBuilds = newValue }
    }

    static var sherpaAutoUnloadEnabled: Bool {
        get { recognition.sherpaAutoUnloadEnabled }
        set { recognition.sherpaAutoUnloadEnabled = newValue }
    }

    static var sherpaAutoUnloadIdleMinutes: Int {
        get { recognition.sherpaAutoUnloadIdleMinutes }
        set { recognition.sherpaAutoUnloadIdleMinutes = newValue }
    }

    static var sherpaProvider: String {
        get { recognition.sherpaProvider }
        set { recognition.sherpaProvider = newValue }
    }

    static var sherpaModelPresetID: String {
        get { recognition.sherpaModelPresetID }
        set { recognition.sherpaModelPresetID = newValue }
    }

    static var sherpaRecognitionLanguage: String {
        get { recognition.sherpaRecognitionLanguage }
        set { recognition.sherpaRecognitionLanguage = newValue }
    }

    static var doubaoASRPrivacyAccepted: Bool {
        get { recognition.doubaoASRPrivacyAccepted }
        set { recognition.doubaoASRPrivacyAccepted = newValue }
    }

    static var doubaoASRLowLatencyDefaultApplied: Bool {
        get { recognition.doubaoASRLowLatencyDefaultApplied }
        set { recognition.doubaoASRLowLatencyDefaultApplied = newValue }
    }

    /// 粘贴后等待目标 App 真正读取剪贴板的延迟，调过 0.15s→0.25s 修复 Electron。
    /// (Post-paste delay so the target app finishes reading the clipboard. Bumped from 0.15s to 0.25s for Electron.)
    static var pasteDelay: Double {
        get { audio.pasteDelay }
        set { audio.pasteDelay = newValue }
    }

    /// 单击说话模式下：true 表示禁用静音自动停止，必须再点一次触发键才结束。
    /// (Tap-to-talk mode: when true, silence auto-stop is disabled — only a 2nd trigger-key tap stops recording.)
    static var tapModeManualStop: Bool {
        get { audio.tapModeManualStop }
        set { audio.tapModeManualStop = newValue }
    }

    /// 使用耳机线控按钮控制录音（单击/长按按当前输入模式匹配，双击回车）。
    /// (Use headphone remote button to control recording — single/long press matches input mode, double tap sends Return.)
    static var headphoneControlEnabled: Bool {
        get { interface.headphoneControlEnabled }
        set { interface.headphoneControlEnabled = newValue }
    }

    static var headphoneControlAlertShown: Bool {
        get { oobe.headphoneControlAlertShown }
        set { oobe.headphoneControlAlertShown = newValue }
    }

    static var hasCompletedOOBE: Bool {
        get { oobe.hasCompletedOOBE }
        set { oobe.hasCompletedOOBE = newValue }
    }
}
