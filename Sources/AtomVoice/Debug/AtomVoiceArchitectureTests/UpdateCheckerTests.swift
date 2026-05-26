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

        await runner.run("Release source match picks Debug Universal when preferDebugBuild=true") {
            let assets: [[String: Any]] = [
                ["name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"],
                ["name": "AtomVoice-0.11.0-AppleSilicon.zip", "browser_download_url": "https://example.com/as.zip"],
                ["name": "AtomVoice-0.11.0-Intel.zip", "browser_download_url": "https://example.com/intel.zip"],
                ["name": "AtomVoice-0.11.0-Debug-Universal.zip", "browser_download_url": "https://example.com/debug.zip"],
            ]
            let result = GitHubReleaseSource.match(
                assets: assets,
                version: "0.11.0",
                isPreRelease: false,
                preferDebugBuild: true
            )
            try expect(result?.assetName == "AtomVoice-0.11.0-Debug-Universal.zip")
            try expect(result?.isDebugBuild == true)
        }

        await runner.run("Release source match excludes Debug asset when preferDebugBuild=false") {
            let assets: [[String: Any]] = [
                ["name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"],
                ["name": "AtomVoice-0.11.0-Universal.zip", "browser_download_url": "https://example.com/u.zip"],
                ["name": "AtomVoice-0.11.0-Debug-Universal.zip", "browser_download_url": "https://example.com/debug.zip"],
            ]
            let result = GitHubReleaseSource.match(
                assets: assets,
                version: "0.11.0",
                isPreRelease: false,
                preferDebugBuild: false
            )
            try expect(result?.assetName == "AtomVoice-0.11.0-Universal.zip")
            try expect(result?.isDebugBuild == false)
        }

        await runner.run("Release source match returns nil when SHA256SUMS.txt missing") {
            let assets: [[String: Any]] = [
                ["name": "AtomVoice-0.11.0-Universal.zip", "browser_download_url": "https://example.com/u.zip"],
            ]
            let result = GitHubReleaseSource.match(
                assets: assets,
                version: "0.11.0",
                isPreRelease: false,
                preferDebugBuild: false
            )
            try expect(result == nil)
        }

        await runner.run("Release source match returns nil when no asset matches channel") {
            let assets: [[String: Any]] = [
                ["name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"],
                ["name": "AtomVoice-0.11.0-Debug-Universal.zip", "browser_download_url": "https://example.com/debug.zip"],
            ]
            let result = GitHubReleaseSource.match(
                assets: assets,
                version: "0.11.0",
                isPreRelease: false,
                preferDebugBuild: false
            )
            try expect(result == nil)
        }
    }
}
