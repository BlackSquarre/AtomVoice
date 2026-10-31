import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum KeychainTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Keychain reads distinguish missing items from denied or undecodable data") {
            try expect(KeychainStore.readResult(status: errSecSuccess, data: Data("known-key".utf8)) == .value("known-key"))
            try expect(KeychainStore.readResult(status: errSecSuccess, data: Data()) == .value(""))
            try expect(KeychainStore.readResult(status: errSecItemNotFound, data: nil) == .notFound)
            try expect(KeychainStore.readResult(status: errSecAuthFailed, data: nil) == .failure(errSecAuthFailed))
            try expect(KeychainStore.readResult(status: errSecInteractionNotAllowed, data: nil) == .failure(errSecInteractionNotAllowed))
            try expect(KeychainStore.readResult(status: errSecSuccess, data: nil) == .failure(errSecDecode))
            try expect(KeychainStore.readResult(status: errSecSuccess, data: Data([0xFF])) == .failure(errSecDecode))
        }

        await runner.run("Keychain empty save never deletes an unread or absent key") {
            var writes = 0
            var deletes = 0
            for read in [KeychainStringReadResult.failure(errSecAuthFailed), .notFound] {
                let saved = KeychainStore.saveString("", previousRead: { read }, write: { _ in
                    writes += 1
                    return true
                }, delete: {
                    deletes += 1
                    return true
                })
                try expect(saved == (read == .notFound))
            }
            try expect(writes == 0)
            try expect(deletes == 0)
        }

        await runner.run("Keychain explicit clear propagates deletion failure") {
            var deletes = 0
            let saved = KeychainStore.saveString("", previousRead: { .value("displayed-key") }, write: { _ in
                false
            }, delete: {
                deletes += 1
                return false
            })
            try expect(!saved)
            try expect(deletes == 1)
        }

        await runner.run("Keychain nonempty replacement does not need to reread the old key") {
            var reads = 0
            var writes: [String] = []
            let saved = KeychainStore.saveString("replacement", previousRead: {
                reads += 1
                return .failure(errSecAuthFailed)
            }, write: {
                writes.append($0)
                return true
            }, delete: { false })
            try expect(saved)
            try expect(reads == 0)
            try expect(writes == ["replacement"])
        }

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
