import Foundation

struct LLMRuntimeSnapshot {
    let connection: LLMConnectionSettings
    let systemPrompt: String
}

enum LLMRuntimeSnapshotResult {
    case disabled
    case unavailable
    case ready(LLMRuntimeSnapshot)
}

final class LLMSettings {
    private let backend: SettingsBackend
    private let apiKeyStore: LLMAPIKeyStoring
    private let credentialLock = NSRecursiveLock()
    private let metadataLock = NSRecursiveLock()
    private let runtimeSnapshotQueue = DispatchQueue(label: "AtomVoice.LLMSettings.runtimeSnapshot", qos: .userInitiated)

    init(backend: SettingsBackend, apiKeyStore: LLMAPIKeyStoring = LLMAPIKeyStore.shared) {
        self.backend = backend
        self.apiKeyStore = apiKeyStore
    }

    var enabled: Bool {
        get { withMetadata { backend.bool(forKey: AppSettings.Keys.llmEnabled, default: false) } }
        set {
            let changed = withMetadata {
                let previous = enabled
                backend.set(newValue, forKey: AppSettings.Keys.llmEnabled)
                return previous != enabled
            }
            if changed { AppSettingsEventBus.publish(.llmEnabledDidChange, from: backend.notificationObject) }
        }
    }

    /// 有效状态不改写用户保存的开关和连接；不适用的引擎也不读取钥匙串。
    func isEnabled(forRecognitionEngine code: String) -> Bool {
        withMetadata {
            guard enabled, let provider = RefinementProvider.forRecognitionEngine(code) else { return false }
            return provider.matches(baseURL: apiBaseURL)
        }
    }

    var apiBaseURL: String {
        get { withMetadata { backend.string(forKey: AppSettings.Keys.llmAPIBaseURL, default: AppSettings.defaultLLMBaseURL) } }
        set { withMetadata { backend.set(newValue, forKey: AppSettings.Keys.llmAPIBaseURL) } }
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
        get { withMetadata { backend.string(forKey: AppSettings.Keys.llmModel, default: AppSettings.defaultLLMModel) } }
        set { withMetadata { backend.set(newValue, forKey: AppSettings.Keys.llmModel) } }
    }

    var systemPrompt: String {
        get { withMetadata { backend.string(forKey: AppSettings.Keys.llmSystemPrompt, default: "") } }
        set { withMetadata { backend.set(newValue, forKey: AppSettings.Keys.llmSystemPrompt) } }
    }

    var resultDelay: Double {
        get { withMetadata { backend.double(forKey: AppSettings.Keys.llmResultDelay, default: 0.3) } }
        set { withMetadata { backend.set(newValue, forKey: AppSettings.Keys.llmResultDelay) } }
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
            withMetadata {
                apiBaseURL = value.baseURL
                model = value.model
            }
            return true
        }
    }
    /// 同一次读取保存凭据状态，界面不把读失败当作空密钥。
    func readConnection() -> (LLMConnectionSettings, KeychainStringReadResult) {
        withCredentials {
            let key = apiKeyStore.readResult()
            return withMetadata { (.init(baseURL: apiBaseURL, apiKey: key.string ?? "", model: model), key) }
        }
    }

    /// 停录入口只排队；凭据读取与 saveConnection 按取得事务锁的顺序执行。
    /// 在后台取得事务锁后冻结非敏感配置，再读取同一事务内的密钥。
    /// 因此快照可以包含排队期间已完成的保存，但不会混配两次保存的连接。
    func readRuntimeSnapshotAsync(forRecognitionEngine code: String,
                                  completion: @escaping (LLMRuntimeSnapshotResult) -> Void) {
        runtimeSnapshotQueue.async { [self] in
            let result = withCredentials { () -> LLMRuntimeSnapshotResult in
                let metadata = withMetadata { () -> (String, String, String)? in
                    guard enabled, let provider = RefinementProvider.forRecognitionEngine(code),
                          provider.matches(baseURL: apiBaseURL) else { return nil }
                    return (apiBaseURL, model, systemPrompt)
                }
                guard let (baseURL, model, systemPrompt) = metadata else { return .disabled }
                guard case .value(let key) = apiKeyStore.readResult(),
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
                return .ready(.init(connection: .init(baseURL: baseURL, apiKey: key, model: model),
                                    systemPrompt: systemPrompt))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 与凭据锁分离，普通设置读取/编辑不等待 Keychain；获取顺序只允许凭据锁→元数据锁。
    private func withMetadata<T>(_ body: () -> T) -> T {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return body()
    }

    private func withCredentials<T>(_ body: () -> T) -> T {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return body()
    }

}
