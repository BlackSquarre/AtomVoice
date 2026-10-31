import Foundation

protocol LLMAPIKeyStoring: AnyObject {
    func readResult() -> KeychainStringReadResult
    @discardableResult
    func write(_ value: String) -> Bool
    @discardableResult
    func delete() -> Bool
}

extension LLMAPIKeyStoring {
    func read() -> String? { readResult().string }
}

final class LLMAPIKeyStore: LLMAPIKeyStoring {
    static let shared = LLMAPIKeyStore()

    private static let service = "com.blacksquarre.AtomVoice.llm"
    private static let account = "apiKey"

    func readResult() -> KeychainStringReadResult {
        KeychainStore.readString(service: Self.service, account: Self.account)
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        KeychainStore.setString(value, service: Self.service, account: Self.account)
    }

    @discardableResult
    func delete() -> Bool {
        KeychainStore.delete(service: Self.service, account: Self.account)
    }
}
