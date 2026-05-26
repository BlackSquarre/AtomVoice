import Foundation

final class LLMSettings {
    static let enabledDidChangeNotification = Notification.Name("LLMSettings.enabledDidChange")

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
            NotificationCenter.default.post(name: Self.enabledDidChangeNotification, object: backend.notificationObject)
        }
    }

    var apiBaseURL: String {
        get { backend.string(forKey: AppSettings.Keys.llmAPIBaseURL, default: AppSettings.defaultLLMBaseURL) }
        set { backend.set(newValue, forKey: AppSettings.Keys.llmAPIBaseURL) }
    }

    var apiKey: String {
        get { apiKeyStore.read() ?? "" }
        set {
            if newValue.isEmpty {
                apiKeyStore.delete()
            } else {
                _ = apiKeyStore.write(newValue)
            }
        }
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
            apiKey = newValue.apiKey
            model = newValue.model
        }
    }
}
