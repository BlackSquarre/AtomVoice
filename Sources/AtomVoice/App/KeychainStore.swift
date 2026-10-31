import Foundation
import Security

enum KeychainStringReadResult: Equatable {
    case value(String)
    case notFound
    case failure(OSStatus)

    var string: String? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

enum KeychainStore {
    static func string(service: String, account: String) -> String? {
        readString(service: service, account: account).string
    }

    static func readString(service: String, account: String) -> KeychainStringReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return readResult(status: status, data: item as? Data)
    }

    static func readResult(status: OSStatus, data: Data?) -> KeychainStringReadResult {
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            return .failure(errSecDecode)
        }
        return .value(value)
    }

    /// 空字段是否代表清空，取决于界面当时实际读到的内容；失败不能当作未配置。
    static func saveString(
        _ value: String,
        previousRead: () -> KeychainStringReadResult,
        write: (String) -> Bool,
        delete: () -> Bool
    ) -> Bool {
        guard value.isEmpty else { return write(value) }
        switch previousRead() {
        case .value:
            return delete()
        case .notFound:
            return true
        case .failure:
            return false
        }
    }

    static func setString(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        return upsertResult(
            updateStatus: updateStatus,
            addItem: {
                var addQuery = query
                addQuery[kSecValueData as String] = data
                return SecItemAdd(addQuery as CFDictionary, nil)
            },
            updateAfterDuplicate: {
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        )
    }

    static func upsertResult(
        updateStatus: OSStatus,
        addItem: () -> OSStatus,
        updateAfterDuplicate: () -> OSStatus
    ) -> Bool {
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let addStatus = addItem()
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            return updateAfterDuplicate() == errSecSuccess
        }

        return false
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
