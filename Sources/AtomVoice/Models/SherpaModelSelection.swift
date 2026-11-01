import Foundation

final class SherpaModelSelection {
    static let shared = SherpaModelSelection()
    private let backend: SettingsBackend
    private let importedStore: SherpaImportedPresetStore
    private let memoryBytes: UInt64
    init(backend: SettingsBackend = AppSettings.backend,
         importedStore: SherpaImportedPresetStore = .shared,
         memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.backend = backend
        self.importedStore = importedStore
        self.memoryBytes = memoryBytes
    }
    var allPresets: [SherpaModelPreset] { SherpaModelCatalog.builtInPresets + importedStore.presets() }
    var recognitionLanguage: String {
        if let language = backend.string(forKey: AppSettings.Keys.sherpaRecognitionLanguage), !language.isEmpty { return language }
        return backend.string(forKey: AppSettings.Keys.selectedLanguage, default: AppSettings.systemDefaultLanguage)
    }
    var current: SherpaModelPreset {
        let id = backend.string(forKey: AppSettings.Keys.sherpaModelPresetID) ?? defaultModelID(for: recognitionLanguage)
        return allPresets.first { $0.id == id } ?? defaultPreset
    }
    var defaultPreset: SherpaModelPreset {
        allPresets.first { $0.id == defaultModelID(for: recognitionLanguage) } ?? SherpaModelCatalog.builtInPresets[0]
    }
    func presets(for language: String) -> [SherpaModelPreset] {
        allPresets.filter { $0.language == language } + (language == "bilingual" ? [] : allPresets.filter { $0.language == "bilingual" })
    }
    func isSelectedPresetID(_ id: String) -> Bool { backend.string(forKey: AppSettings.Keys.sherpaModelPresetID) == id }
    func selectPreset(_ id: String) { RecognitionSettings(backend: backend).sherpaModelPresetID = id }
    func selectProvider(_ provider: String) { RecognitionSettings(backend: backend).sherpaProvider = provider }
    func select(language: String, presetID: String, provider: String? = nil) {
        RecognitionSettings(backend: backend).sherpaRecognitionLanguage = language
        selectPreset(presetID)
        if let provider { selectProvider(provider) }
    }
    func changeLanguage(_ language: String) {
        RecognitionSettings(backend: backend).sherpaRecognitionLanguage = language
        let saved = backend.string(forKey: AppSettings.Keys.sherpaModelPresetID)
        if saved == nil || !presets(for: language).contains(where: { $0.id == saved }) {
            selectPreset(defaultModelID(for: language))
        }
    }

    func defaultModelID(for language: String) -> String {
        let lowMem = memoryBytes / (1024 * 1024 * 1024) <= 8
        switch language {
        case "zh-CN": return lowMem ? "zh-14M" : "zh-multi"
        case "en-US": return lowMem ? "en-20M" : "en-standard"
        case "bilingual": return lowMem ? "bilingual-small" : "bilingual"
        case "ja-JP": return "japanese"
        case "ko-KR": return "korean"
        case "fr-FR": return "french"
        case "zh-TW", "es-ES", "de-DE":
            return importedStore.presets().first { $0.language == language }?.id ?? (lowMem ? "zh-14M" : "zh-multi")
        default: return lowMem ? "zh-14M" : "zh-multi"
        }
    }
}
