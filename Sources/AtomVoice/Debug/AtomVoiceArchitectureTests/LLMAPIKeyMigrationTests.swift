import Foundation
import Security
@testable import AtomVoiceCore

private final class FakeLLMAPIKeyStore: LLMAPIKeyStoring {
    var storedValue: String?
    var writes: [String] = []
    var deletes = 0
    var shouldWriteSucceed = true
    var shouldDeleteSucceed = true
    var readFailure: OSStatus?
    var reads = 0

    func readResult() -> KeychainStringReadResult {
        reads += 1
        if let readFailure { return .failure(readFailure) }
        return storedValue.map(KeychainStringReadResult.value) ?? .notFound
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        writes.append(value)
        guard shouldWriteSucceed else { return false }
        storedValue = value
        return true
    }

    @discardableResult
    func delete() -> Bool {
        deletes += 1
        guard shouldDeleteSucceed else { return false }
        storedValue = nil
        return true
    }
}

enum LLMAPIKeyMigrationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Independent refinement is effective only for OpenAI recognition without accessing credentials") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "offline-retained-key"
            keyStore.readFailure = errSecAuthFailed
            let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)
            settings.enabled = true
            settings.apiBaseURL = "https://api.openai.com/v1"
            settings.model = "offline-custom-model"
            settings.systemPrompt = "offline retained instructions"
            settings.resultDelay = 0.7

            for engine in ["apple", "sherpaOnnx", "doubao", "openai"] {
                try expect(settings.isEnabled(forRecognitionEngine: engine) == (engine == "openai"), engine)
                try expect((RefinementProvider.forRecognitionEngine(engine) != nil) == (engine == "openai"), engine)
            }
            settings.enabled = false
            for engine in ["apple", "sherpaOnnx", "doubao", "openai"] {
                try expect(!settings.isEnabled(forRecognitionEngine: engine), engine)
            }
            settings.enabled = true
            try expect(settings.isEnabled(forRecognitionEngine: "openai"))
            try expect(settings.model == "offline-custom-model")
            try expect(settings.systemPrompt == "offline retained instructions" && settings.resultDelay == 0.7)
            try expect(keyStore.reads == 0 && keyStore.writes.isEmpty && keyStore.deletes == 0,
                       "Engine policy must not read, replace, or delete any stored API key")
            try expect(keyStore.storedValue == "offline-retained-key")
        }

        await runner.run("OpenAI refinement accepts official HTTPS API paths and rejects proxy or lookalike URLs") {
            for url in [
                "https://api.openai.com/v1", "https://api.openai.com/v1/",
                "https://api.openai.com/v1/chat", "https://api.openai.com/v1/chat/completions/",
                " https://API.OPENAI.COM:443/v1 \n",
            ] {
                try expect(RefinementProvider.openAI.matches(baseURL: url), url)
            }
            for url in [
                "", "http://api.openai.com/v1", "https://api.openai.com:8443/v1",
                "https://api.openai.com.evil.invalid/v1", "https://proxy.invalid/openai/v1",
                "https://api.openai.com@proxy.invalid/v1", "https://name@api.openai.com/v1",
                "https://api.openai.com/v2", "https://api.openai.com/v1/responses",
                "https://api.openai.com/v1?redirect=proxy", "https://api.openai.com/v1#proxy",
            ] {
                try expect(!RefinementProvider.openAI.matches(baseURL: url), url)
            }
        }

        await runner.run("Unsupported engines and a legacy provider leave disabled refinement configuration intact") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "offline-legacy-provider-key"
            let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)
            settings.enabled = true
            settings.apiBaseURL = "https://legacy-provider.invalid/v1"
            settings.model = "offline-legacy-model"
            settings.systemPrompt = "offline legacy prompt"
            settings.resultDelay = 0.9
            ProviderStore.save([.init(name: "Offline provider", baseURL: settings.apiBaseURL,
                                      defaultModel: settings.model)], backend: backend)
            let providerData = backend.data(forKey: AppSettings.Keys.llmProviders)

            for engine in ["apple", "sherpaOnnx", "doubao", "openai", "unknown"] {
                try expect(!settings.isEnabled(forRecognitionEngine: engine), engine)
            }
            try expect(settings.enabled, "Hiding or suspending refinement must preserve the user's raw switch")
            try expect(settings.apiBaseURL == "https://legacy-provider.invalid/v1")
            try expect(settings.model == "offline-legacy-model")
            try expect(settings.systemPrompt == "offline legacy prompt" && settings.resultDelay == 0.9)
            try expect(backend.data(forKey: AppSettings.Keys.llmProviders) == providerData)
            try expect(keyStore.storedValue == "offline-legacy-provider-key")
            try expect(keyStore.reads == 0 && keyStore.writes.isEmpty && keyStore.deletes == 0)
        }

        for deleting in [false, true] {
            await runner.run("LLM failed connection commit preserves URL model and key, deleting=\(deleting)") {
                let backend = InMemorySettingsBackend()
                let keyStore = FakeLLMAPIKeyStore()
                keyStore.storedValue = "old-key"
                let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)
                settings.apiBaseURL = "https://old.invalid/v1"
                settings.model = "old-model"
                keyStore.shouldWriteSucceed = false
                keyStore.shouldDeleteSucceed = false
                let changed = LLMConnectionSettings(baseURL: "https://new.invalid/v1", apiKey: deleting ? "" : "new-key", model: "new-model")
                try expect(!settings.saveConnection(changed, previousKeyRead: .value("old-key")))
                try expect(settings.apiBaseURL == "https://old.invalid/v1")
                try expect(settings.model == "old-model")
                try expect(keyStore.storedValue == "old-key")
            }
        }

        await runner.run("LLM migration preserves legacy data and flag when Keychain read is denied") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "protected-key"
            keyStore.readFailure = errSecAuthFailed
            backend.set("legacy-key", forKey: AppSettings.Keys.llmAPIKey)

            LLMAPIKeyMigration.runIfNeeded(backend: backend, apiKeyStore: keyStore)

            try expect(keyStore.storedValue == "protected-key")
            try expect(keyStore.writes.isEmpty)
            try expect(keyStore.deletes == 0)
            try expect(backend.string(forKey: AppSettings.Keys.llmAPIKey) == "legacy-key")
            try expect(!backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false))
        }

        await runner.run("LLM blank form cannot clear a key that was unreadable when displayed") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "protected-key"
            keyStore.readFailure = errSecAuthFailed
            let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)
            let displayedRead = settings.apiKeyReadResult
            try expect(displayedRead.string == nil)

            // 底层恢复可读，不能把这一变化当成用户曾看见并主动清空密钥。
            keyStore.readFailure = nil
            let blankForm = LLMConnectionSettings(baseURL: "https://example.invalid/v1", apiKey: "", model: "test-model")
            try expect(!settings.saveConnection(blankForm, previousKeyRead: displayedRead))
            try expect(keyStore.storedValue == "protected-key")
            try expect(keyStore.deletes == 0)
            try expect(keyStore.reads == 1)
        }

        await runner.run("LLM explicitly clearing a displayed key succeeds but deletion failures are reported") {
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "displayed-key"
            let settings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: keyStore)
            let displayedRead = settings.apiKeyReadResult
            keyStore.shouldDeleteSucceed = false
            try expect(!settings.saveAPIKey("", previousRead: displayedRead))
            try expect(keyStore.storedValue == "displayed-key")
            keyStore.shouldDeleteSucceed = true
            try expect(settings.saveAPIKey("", previousRead: displayedRead))
            try expect(keyStore.storedValue == nil)
            try expect(keyStore.deletes == 2)
        }

        await runner.run("LLM empty form does not delete a key added after an absent read") {
            let keyStore = FakeLLMAPIKeyStore()
            let settings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: keyStore)
            let displayedRead = settings.apiKeyReadResult
            keyStore.storedValue = "newly-added-key"
            try expect(settings.saveAPIKey("", previousRead: displayedRead))
            try expect(keyStore.storedValue == "newly-added-key")
            try expect(keyStore.deletes == 0)
        }

        await runner.run("LLM allows an entered replacement after a failed read without deleting the old key") {
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "protected-key"
            keyStore.readFailure = errSecAuthFailed
            let settings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: keyStore)
            let displayedRead = settings.apiKeyReadResult
            try expect(settings.saveAPIKey("replacement-key", previousRead: displayedRead))
            try expect(keyStore.storedValue == "replacement-key")
            try expect(keyStore.writes == ["replacement-key"])
            try expect(keyStore.deletes == 0)
            try expect(keyStore.reads == 1)
        }

        await runner.run("LLM API key migration moves legacy key to Keychain and clears UserDefaults") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            backend.set("legacy-key", forKey: AppSettings.Keys.llmAPIKey)

            LLMAPIKeyMigration.runIfNeeded(backend: backend, apiKeyStore: keyStore)

            try expect(keyStore.storedValue == "legacy-key")
            try expect(keyStore.writes == ["legacy-key"])
            let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)
            try expect(settings.connection.apiKey == "legacy-key")
            try expect(backend.string(forKey: AppSettings.Keys.llmAPIKey) == nil)
            try expect(backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false))
        }

        await runner.run("LLM API key migration is no-op after migrated flag is set") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "existing-keychain-key"
            backend.set("legacy-key", forKey: AppSettings.Keys.llmAPIKey)
            backend.set(true, forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain)

            LLMAPIKeyMigration.runIfNeeded(backend: backend, apiKeyStore: keyStore)

            try expect(keyStore.storedValue == "existing-keychain-key")
            try expect(keyStore.writes.isEmpty)
            try expect(backend.string(forKey: AppSettings.Keys.llmAPIKey) == "legacy-key")
            try expect(backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false))
        }

        await runner.run("LLM API key migration preserves Keychain value when both legacy and Keychain are non-empty") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.storedValue = "keychain-key"
            backend.set("stale-legacy", forKey: AppSettings.Keys.llmAPIKey)

            LLMAPIKeyMigration.runIfNeeded(backend: backend, apiKeyStore: keyStore)

            try expect(keyStore.storedValue == "keychain-key")
            try expect(keyStore.writes.isEmpty)
            try expect(backend.string(forKey: AppSettings.Keys.llmAPIKey) == nil)
            try expect(backend.bool(forKey: AppSettings.Keys.llmAPIKeyMigratedToKeychain, default: false))
        }

        await runner.run("LLM settings reports Keychain write failures") {
            let backend = InMemorySettingsBackend()
            let keyStore = FakeLLMAPIKeyStore()
            keyStore.shouldWriteSucceed = false
            let settings = LLMSettings(backend: backend, apiKeyStore: keyStore)

            try expect(!settings.saveAPIKey("unwritable-key"))
            try expect(settings.apiKey.isEmpty)
            try expect(keyStore.writes == ["unwritable-key"])
        }
    }
}
