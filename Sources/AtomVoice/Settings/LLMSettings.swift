import Foundation

final class LLMSettings {
    private let backend: SettingsBackend
    private let apiKeyStore: LLMAPIKeyStoring
    private let credentialLock = NSRecursiveLock()

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

    /// 有效状态不改写用户保存的开关和连接；不适用的引擎也不读取钥匙串。
    func isEnabled(forRecognitionEngine code: String) -> Bool {
        guard enabled, let provider = RefinementProvider.forRecognitionEngine(code) else { return false }
        return provider.matches(baseURL: apiBaseURL)
    }

    var apiBaseURL: String {
        get { backend.string(forKey: AppSettings.Keys.llmAPIBaseURL, default: AppSettings.defaultLLMBaseURL) }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmAPIBaseURL) }
    }

    var apiKey: String {
        get { withCredentials { apiKeyStore.read() ?? "" } }
        set {
            _ = saveAPIKey(newValue)
        }
    }

    var apiKeyReadResult: KeychainStringReadResult { withCredentials { apiKeyStore.readResult() } }

    /// 保存 API key，并把 Keychain 写入结果返回给设置界面。
    /// (Save the API key and expose the Keychain result to settings UI.)
    @discardableResult
    func saveAPIKey(_ value: String, previousRead: KeychainStringReadResult? = nil) -> Bool {
        withCredentials { KeychainStore.saveString(
            value,
            previousRead: { previousRead ?? self.apiKeyStore.readResult() },
            write: apiKeyStore.write,
            delete: apiKeyStore.delete
        ) }
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
        get { readConnection().0 }
        set {
            _ = saveConnection(newValue)
        }
    }

    /// 先提交密钥；失败时保留整组旧连接配置。
    @discardableResult
    func saveConnection(_ value: LLMConnectionSettings, previousKeyRead: KeychainStringReadResult? = nil) -> Bool {
        withCredentials {
            guard saveAPIKey(value.apiKey, previousRead: previousKeyRead) else { return false }
            apiBaseURL = value.baseURL
            model = value.model
            return true
        }
    }
    /// 同一次读取保存凭据状态，界面不把读失败当作空密钥。
    func readConnection() -> (LLMConnectionSettings, KeychainStringReadResult) {
        withCredentials {
            let key = apiKeyStore.readResult()
            return (.init(baseURL: apiBaseURL, apiKey: key.string ?? "", model: model), key)
        }
    }

    private func withCredentials<T>(_ body: () -> T) -> T {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return body()
    }

}
