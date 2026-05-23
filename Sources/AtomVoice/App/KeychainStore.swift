import Foundation
import Security

enum KeychainStore {
    static func string(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
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

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
