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
        await runner.run("Update installer binds equivalent release versions") {
            let compare: (String, String) -> Bool = { UpdateChecker.isNewer($0, than: $1) }
            try expect(BundleUpdateInstaller.versionsAreEquivalent("0.10.1-Beta-2", "0.10.1 Beta 2", isNewer: compare))
            try expect(BundleUpdateInstaller.versionsAreEquivalent("v0.10.1-beta_2", "0.10.1-Beta-2", isNewer: compare))
            try expect(BundleUpdateInstaller.versionsAreEquivalent("1.2", "1.2.0", isNewer: compare))
            try expect(!BundleUpdateInstaller.versionsAreEquivalent("0.10.1-Beta-3", "0.10.1-Beta-2", isNewer: compare))
            try expect(!BundleUpdateInstaller.versionsAreEquivalent("0.11.2", "0.11.1", isNewer: compare))
            try expect(!BundleUpdateInstaller.versionsAreEquivalent("0.11.1", "0.11.1-Beta-1", isNewer: compare))
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

        await runner.run("Release summary selects Chinese and falls back to English") {
            let body = """
              <!-- atomvoice-summary-en: Faster transcription and safer updates. -->
              <!-- atomvoice-summary-zh: 转写更快，更新更安全。 -->
            ## What's New
            """
            try expect(GitHubReleaseSource.releaseSummary(from: body, preferredLanguages: ["zh-Hans"]) == "转写更快，更新更安全。")
            try expect(GitHubReleaseSource.releaseSummary(from: body, preferredLanguages: ["zh-Hant-HK"]) == "转写更快，更新更安全。")
            try expect(GitHubReleaseSource.releaseSummary(from: body, preferredLanguages: ["ja-JP"]) == "Faster transcription and safer updates.")

            let englishOnly = "<!-- atomvoice-summary-en: English fallback. -->"
            try expect(GitHubReleaseSource.releaseSummary(from: englishOnly, preferredLanguages: ["zh-CN"]) == "English fallback.")
        }

        await runner.run("Release summary rejects malformed markers and sanitizes plain text") {
            try expect(GitHubReleaseSource.releaseSummary(from: "No marker", preferredLanguages: ["en"]) == nil)
            try expect(GitHubReleaseSource.releaseSummary(from: "<!-- atomvoice-summary-en: -->", preferredLanguages: ["en"]) == nil)
            try expect(GitHubReleaseSource.releaseSummary(from: "<!-- atomvoice-summary-en: Missing close", preferredLanguages: ["en"]) == nil)
            let duplicate = """
            <!-- atomvoice-summary-en: First. -->
            <!-- atomvoice-summary-en: Second. -->
            """
            try expect(GitHubReleaseSource.releaseSummary(from: duplicate, preferredLanguages: ["en"]) == nil)

            let unsafe = "<!-- atomvoice-summary-en: Safe\u{0000}\u{0080}\u{202E}\u{2066}团队👩‍💻 [link](https://example.com) <script> -->"
            let expected = "Safe团队👩‍💻 [link](https://example.com) <script>"
            try expect(GitHubReleaseSource.releaseSummary(from: unsafe, preferredLanguages: ["en"]) == expected)
        }

        await runner.run("Release summary truncates by Character without splitting Unicode") {
            let longText = String(repeating: "语", count: 300)
            let body = "<!-- atomvoice-summary-en: \(longText) -->"
            let summary = try require(GitHubReleaseSource.releaseSummary(from: body, preferredLanguages: ["en"]))
            try expect(summary.count == 240)
            try expect(summary == String(repeating: "语", count: 239) + "…")

            let combining = "a" + String(repeating: "\u{0301}", count: 5_000)
            let pathologicalBody = "<!-- atomvoice-summary-en: \(combining) -->"
            let bounded = try require(GitHubReleaseSource.releaseSummary(from: pathologicalBody, preferredLanguages: ["en"]))
            try expect(bounded.unicodeScalars.count <= 1_024)
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
                preferDebugBuild: true,
                summary: "Fixture summary"
            )
            try expect(result?.assetName == "AtomVoice-0.11.0-Debug-Universal.zip")
            try expect(result?.isDebugBuild == true)
            try expect(result?.summary == "Fixture summary")
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
