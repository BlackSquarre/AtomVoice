import Foundation
@testable import AtomVoiceCore

private final class FakeLLMAPIKeyStore: LLMAPIKeyStoring {
    var storedValue: String?
    var writes: [String] = []
    var deletes = 0
    var shouldWriteSucceed = true

    func read() -> String? { storedValue }

    @discardableResult
    func write(_ value: String) -> Bool {
        writes.append(value)
        guard shouldWriteSucceed else { return false }
        storedValue = value
        return true
    }

    func delete() {
        deletes += 1
        storedValue = nil
    }
}

enum LLMAPIKeyMigrationTests {
    static func run(_ runner: inout TestRunner) async {
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
    }
}
