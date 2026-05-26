import Foundation

enum LLMAPIKeyMigration {
    static func runIfNeeded(
        backend: SettingsBackend,
        apiKeyStore: LLMAPIKeyStoring = LLMAPIKeyStore.shared
    ) {
        guard !backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false) else { return }

        if let legacy = backend.string(forKey: AppSettings.Keys.llmAPIKey), !legacy.isEmpty {
            guard apiKeyStore.write(legacy) else {
                DebugLog.error("[LLM] Failed to migrate API key to Keychain")
                return
            }
        }

        backend.set(nil, forKey: AppSettings.Keys.llmAPIKey)
        backend.set(true, forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain)
    }
}
