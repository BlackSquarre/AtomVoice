import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum KeychainTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Keychain upsert updates, adds, and recovers duplicate add") {
            var operations: [String] = []

            let updated = KeychainStore.upsertResult(
                updateStatus: errSecSuccess,
                addItem: {
                    operations.append("add")
                    return errSecSuccess
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(updated)
            try expect(operations.isEmpty)

            operations.removeAll()
            let added = KeychainStore.upsertResult(
                updateStatus: errSecItemNotFound,
                addItem: {
                    operations.append("add")
                    return errSecSuccess
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(added)
            try expect(operations == ["add"])

            operations.removeAll()
            let recoveredDuplicate = KeychainStore.upsertResult(
                updateStatus: errSecItemNotFound,
                addItem: {
                    operations.append("add")
                    return errSecDuplicateItem
                },
                updateAfterDuplicate: {
                    operations.append("updateAfterDuplicate")
                    return errSecSuccess
                }
            )
            try expect(recoveredDuplicate)
            try expect(operations == ["add", "updateAfterDuplicate"])
        }
    }
}
