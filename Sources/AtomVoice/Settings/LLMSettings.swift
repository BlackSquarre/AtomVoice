import Foundation

final class LLMSettings {
    private let backend: SettingsBackend
    private let apiKeyStore: LLMAPIKeyStoring

    init(backend: SettingsBackend, apiKeyStore: LLMAPIKeyStoring = LLMAPIKeyStore.shared) {
        self.backend = backend
        self.apiKeyStore = apiKeyStore
    }

    var enabled: Bool {
        get { backend.bool(forKey: AppSettings.Keys.llmEnabled, default: false) }
        set {
            let oldValue = enabled
            backend.set(newValue, forKey: AppSettings.Keys.llmEnabled)
            guard oldValue != enabled else { return }
            AppSettingsEventBus.publish(.llmEnabledDidChange, from: backend.notificationObject)
        }
    }

    var apiBaseURL: String {
        get { backend.string(forKey: AppSettings.Keys.llmAPIBaseURL, default: AppSettings.defaultLLMBaseURL) }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmAPIBaseURL) }
    }

    var apiKey: String {
        get { apiKeyStore.read() ?? "" }
        set {
            _ = saveAPIKey(newValue)
        }
    }

    var apiKeyReadResult: KeychainStringReadResult { apiKeyStore.readResult() }

    /// 保存 API key，并把 Keychain 写入结果返回给设置界面。
    /// (Save the API key and expose the Keychain result to settings UI.)
    @discardableResult
    func saveAPIKey(_ value: String, previousRead: KeychainStringReadResult? = nil) -> Bool {
        KeychainStore.saveString(
            value,
            previousRead: { previousRead ?? self.apiKeyStore.readResult() },
            write: apiKeyStore.write,
            delete: apiKeyStore.delete
        )
    }

    var model: String {
        get { backend.string(forKey: AppSettings.Keys.llmModel, default: AppSettings.defaultLLMModel) }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmModel) }
    }

    var systemPrompt: String {
        get { backend.string(forKey: AppSettings.Keys.llmSystemPrompt, default: "") }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmSystemPrompt) }
    }

    var resultDelay: Double {
        get { backend.double(forKey: AppSettings.Keys.llmResultDelay, default: 0.3) }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmResultDelay) }
    }

    var connection: LLMConnectionSettings {
        get {
            LLMConnectionSettings(
                baseURL: apiBaseURL,
                apiKey: apiKey,
                model: model
            )
        }
        set {
            _ = saveConnection(newValue)
        }
    }

    /// 先提交密钥；失败时保留整组旧连接配置。
    @discardableResult
    func saveConnection(_ value: LLMConnectionSettings, previousKeyRead: KeychainStringReadResult? = nil) -> Bool {
        guard saveAPIKey(value.apiKey, previousRead: previousKeyRead) else { return false }
        apiBaseURL = value.baseURL
        model = value.model
        return true
    }
}
