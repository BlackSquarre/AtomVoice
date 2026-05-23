import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum UpdateCheckerTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Update checker parses versions and compares pre-release") {
            let checker = UpdateChecker.shared
            let parsed = checker.parseVersion("v0.10.4-Beta-2")

            try expect(parsed.numbers == [0, 10, 4])
            try expect(parsed.preRelease == ["beta", "2"])
            try expect(checker.isNewer("0.10.5", than: "0.10.4"))
            try expect(checker.isNewer("0.10.4", than: "0.10.4-Beta-2"))
            try expect(checker.isNewer("0.10.4-Beta-3", than: "0.10.4-Beta-2"))
            try expect(!checker.isNewer("0.10.4-Beta-2", than: "0.10.4"))
            try expect(checker.comparePreRelease(["beta", "10"], ["beta", "2"]) == .orderedDescending)
            try expect(checker.comparePreRelease(["beta"], ["beta", "1"]) == .orderedAscending)
        }
        await runner.run("Update checker extracts checksum by asset name") {
            let checker = UpdateChecker.shared
            let listing = """
            0123456789ABCDEF  AtomVoice-0.10.4.zip
            abcdef0123456789 *AtomVoice-0.10.4-Debug.zip
            """

            try expect(checker.expectedChecksum(in: listing, assetName: "AtomVoice-0.10.4.zip") == "0123456789abcdef")
            try expect(checker.expectedChecksum(in: listing, assetName: "AtomVoice-0.10.4-Debug.zip") == "abcdef0123456789")
            try expect(checker.expectedChecksum(in: listing, assetName: "missing.zip") == nil)
        }
    }
}
