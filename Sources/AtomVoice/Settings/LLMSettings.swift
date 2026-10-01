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

    /// 保存 API key，并把 Keychain 写入结果返回给设置界面。
    /// (Save the API key and expose the Keychain result to settings UI.)
    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        if value.isEmpty {
            apiKeyStore.delete()
            return true
        }
        return apiKeyStore.write(value)
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
            apiBaseURL = newValue.baseURL
            _ = saveAPIKey(newValue.apiKey)
            model = newValue.model
        }
    }

    /// 更新连接配置；API key 写入失败时返回 false，其他非敏感设置仍会保存。
    /// (Update connection settings; returns false if Keychain persistence fails.)
    @discardableResult
    func saveConnection(_ value: LLMConnectionSettings) -> Bool {
        apiBaseURL = value.baseURL
        let keySaved = saveAPIKey(value.apiKey)
        model = value.model
        return keySaved
    }
}
