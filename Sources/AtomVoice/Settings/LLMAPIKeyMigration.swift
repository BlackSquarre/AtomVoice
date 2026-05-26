import Foundation

enum LLMAPIKeyMigration {
    static func runIfNeeded(
        backend: SettingsBackend,
        apiKeyStore: LLMAPIKeyStoring = LLMAPIKeyStore.shared
    ) {
        guard !backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false) else { return }

        if let legacy = backend.string(forKey: AppSettings.Keys.llmAPIKey), !legacy.isEmpty {
            // 仅当 Keychain 当前为空时才迁移；防止版本回退场景下 legacy 覆盖 Keychain 已有值。
            // (Only migrate when Keychain is empty; prevents legacy from overwriting Keychain on version rollback.)
            if (apiKeyStore.read() ?? "").isEmpty {
                guard apiKeyStore.write(legacy) else {
                    DebugLog.error("[LLM] Failed to migrate API key to Keychain")
                    return
                }
            }
        }

        backend.set(nil, forKey: AppSettings.Keys.llmAPIKey)
        backend.set(true, forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain)
    }
}
