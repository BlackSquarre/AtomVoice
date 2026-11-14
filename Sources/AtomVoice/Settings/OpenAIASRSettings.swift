import Foundation

enum OpenAIASRModel: String, Codable, CaseIterable {
    case live = "gpt-live-transcribe"
    case whisper = "gpt-realtime-whisper"

    var supportsContext: Bool { self == .live }
    var supportsMultipleLanguages: Bool { self == .live }
}

struct OpenAIASRConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var model: OpenAIASRModel? = nil
    var delay: String? = nil
    var languages: [String] = []
    var prompt = ""
    var keywords: [String] = []

    var resolvedModel: OpenAIASRModel { model ?? .live }

    func validated(selectedLanguage: String? = nil) throws -> Self {
        let delays: Set<String> = ["minimal", "low", "medium", "high", "xhigh"]
        let supported: Set<String> = ["en", "zh", "zh-cn", "zh-tw", "zh-hk", "cmn", "yue", "ja", "ko", "es", "fr", "de"]
        guard schemaVersion == 1, delay.map({ delays.contains($0) }) ?? true else {
            throw OpenAIASRSettingsError.invalidConfiguration
        }
        var result = self
        // 默认模型使用缺省值存储，兼容旧配置并避免仅刷新模型列表就产生修改。
        result.model = resolvedModel == .live ? nil : resolvedModel
        let mapping = ["en-US": "en", "zh-CN": "zh-cn", "zh-TW": "zh-tw", "ja-JP": "ja", "ko-KR": "ko", "es-ES": "es", "fr-FR": "fr", "de-DE": "de"]
        var languageValues = languages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        if languageValues.isEmpty, let selectedLanguage {
            languageValues = [mapping[selectedLanguage] ?? "en"]
        }
        guard languageValues.allSatisfy({ supported.contains($0) }) else {
            throw OpenAIASRSettingsError.invalidConfiguration
        }
        var seen = Set<String>()
        if resolvedModel == .whisper {
            let whisperSupported: Set<String> = ["en", "zh", "ja", "ko", "es", "fr", "de"]
            let chineseVariants: Set<String> = ["zh-cn", "zh-tw", "zh-hk", "cmn"]
            languageValues = languageValues.map { chineseVariants.contains($0) ? "zh" : $0 }
            guard languageValues.allSatisfy({ whisperSupported.contains($0) }) else {
                throw OpenAIASRSettingsError.invalidConfiguration
            }
        }
        result.languages = languageValues.filter { seen.insert($0).inserted }
        guard resolvedModel.supportsMultipleLanguages || result.languages.count <= 1 else {
            throw OpenAIASRSettingsError.invalidConfiguration
        }
        result.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        seen.removeAll()
        result.keywords = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard result.keywords.allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil }) else {
            throw OpenAIASRSettingsError.invalidConfiguration
        }
        return result
    }
}

enum OpenAIASRSettingsError: Error {
    case invalidConfiguration, missingKey, keychainUnavailable

    var message: String {
        switch self {
        case .invalidConfiguration: return loc("openai.error.invalidConfiguration")
        case .missingKey: return loc("openai.error.missingApiKey")
        case .keychainUnavailable: return loc("openai.error.keychainFailed")
        }
    }
}

/// 只在创建本轮连接时读取，避免表单保存改变正在发送的音频配置。
struct OpenAIASRRuntimeSettings {
    let apiKey: String
    let configuration: OpenAIASRConfiguration
}

final class OpenAIASRSettings {
    static let engineCode = "openai"
    static let model = OpenAIASRModel.live.rawValue
    static let endpoint = "wss://api.openai.com/v1/realtime?intent=transcription"
    static let keychainService = "com.blacksquarre.AtomVoice.openaiASR"
    static let keychainAccount = "apiKey"

    private let backend: SettingsBackend
    private let readKey: () -> KeychainStringReadResult
    private let writeKey: (String) -> Bool
    private let deleteKey: () -> Bool
    private let lock = NSRecursiveLock()

    init(backend: SettingsBackend,
         readKey: @escaping () -> KeychainStringReadResult = { KeychainStore.readString(service: OpenAIASRSettings.keychainService, account: OpenAIASRSettings.keychainAccount) },
         writeKey: @escaping (String) -> Bool = { KeychainStore.setString($0, service: OpenAIASRSettings.keychainService, account: OpenAIASRSettings.keychainAccount) },
         deleteKey: @escaping () -> Bool = { KeychainStore.delete(service: OpenAIASRSettings.keychainService, account: OpenAIASRSettings.keychainAccount) }) {
        self.backend = backend
        self.readKey = readKey
        self.writeKey = writeKey
        self.deleteKey = deleteKey
    }

    var privacyAccepted: Bool {
        get { locked { backend.bool(forKey: AppSettings.Keys.openaiASRPrivacyAccepted, default: false) } }
        set { locked { backend.set(newValue, forKey: AppSettings.Keys.openaiASRPrivacyAccepted) } }
    }

    func configuration() throws -> OpenAIASRConfiguration {
        try locked {
            guard let data = backend.data(forKey: AppSettings.Keys.openaiASRConfiguration) else { return .init() }
            guard let value = try? JSONDecoder().decode(OpenAIASRConfiguration.self, from: data) else {
                throw OpenAIASRSettingsError.invalidConfiguration
            }
            return try value.validated()
        }
    }

    func apiKeyReadResult() -> KeychainStringReadResult { locked { readKey() } }

    func snapshot(selectedLanguage: String = AppSettings.selectedLanguage) throws -> OpenAIASRRuntimeSettings {
        try locked {
            let value = try configuration().validated(selectedLanguage: selectedLanguage)
            switch readKey() {
            case .value(let raw):
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw OpenAIASRSettingsError.missingKey }
                return .init(apiKey: key, configuration: value)
            case .notFound: throw OpenAIASRSettingsError.missingKey
            case .failure: throw OpenAIASRSettingsError.keychainUnavailable
            }
        }
    }

    /// 密钥未编辑时不读取或覆写；同意标记不属于表单，旧草稿不能覆盖新确认。
    func save(_ configuration: OpenAIASRConfiguration, keyEdit: OpenAIASRKeyEdit,
              previousKeyRead: KeychainStringReadResult) throws {
        try locked {
            let value = try configuration.validated()
            let data = try JSONEncoder().encode(value)
            switch keyEdit {
            case .unchanged: break
            case .replace(let raw):
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw OpenAIASRSettingsError.missingKey }
                guard writeKey(key) else { throw OpenAIASRSettingsError.keychainUnavailable }
            case .clear:
                guard KeychainStore.saveString("", previousRead: { previousKeyRead }, write: writeKey, delete: deleteKey) else {
                    throw OpenAIASRSettingsError.keychainUnavailable
                }
            }
            backend.set(data, forKey: AppSettings.Keys.openaiASRConfiguration)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum OpenAIASRKeyEdit: Equatable {
    case unchanged, replace(String), clear
}

struct OpenAIASRSettingsDraft: Equatable {
    var configuration: OpenAIASRConfiguration
    var keyEdit: OpenAIASRKeyEdit = .unchanged
}

final class OpenAIASRSettingsEditor {
    private let settings: OpenAIASRSettings
    private(set) var baseline: OpenAIASRSettingsDraft?
    private(set) var keyReadResult: KeychainStringReadResult = .notFound
    private(set) var loadError: String?

    init(settings: OpenAIASRSettings = AppSettings.openaiASR) { self.settings = settings }

    func reload() -> OpenAIASRSettingsDraft {
        keyReadResult = settings.apiKeyReadResult()
        let configuration: OpenAIASRConfiguration
        do {
            configuration = try settings.configuration()
            loadError = nil
        } catch {
            configuration = .init()
            loadError = loc("openai.error.invalidConfiguration")
        }
        let draft = OpenAIASRSettingsDraft(configuration: configuration)
        baseline = draft
        return draft
    }

    func hasChanges(_ draft: OpenAIASRSettingsDraft) -> Bool {
        guard let baseline else { return false }
        let value = (try? draft.configuration.validated()) ?? draft.configuration
        return value != baseline.configuration || draft.keyEdit != .unchanged
    }

    func save(_ draft: OpenAIASRSettingsDraft) throws {
        guard hasChanges(draft) else { return }
        try settings.save(draft.configuration, keyEdit: draft.keyEdit, previousKeyRead: keyReadResult)
        switch draft.keyEdit {
        case .unchanged: break
        case .replace(let key): keyReadResult = .value(key.trimmingCharacters(in: .whitespacesAndNewlines))
        case .clear: keyReadResult = .notFound
        }
        baseline = .init(configuration: try draft.configuration.validated())
        loadError = nil
    }
}
