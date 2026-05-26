import Foundation

protocol LLMAPIKeyStoring: AnyObject {
    func read() -> String?
    @discardableResult
    func write(_ value: String) -> Bool
    func delete()
}

final class LLMAPIKeyStore: LLMAPIKeyStoring {
    static let shared = LLMAPIKeyStore()

    private static let service = "com.blacksquarre.AtomVoice.llm"
    private static let account = "apiKey"

    func read() -> String? {
        KeychainStore.string(service: Self.service, account: Self.account)
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        KeychainStore.setString(value, service: Self.service, account: Self.account)
    }

    func delete() {
        KeychainStore.delete(service: Self.service, account: Self.account)
    }
}
