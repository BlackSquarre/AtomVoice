import AppKit
import Foundation
@testable import AtomVoiceCore

enum OOBELayoutTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"]

    static func run(_ runner: inout TestRunner) async {
        await runner.run("OOBE English copy uses sentence-style capitalization") {
            let root = try repositoryRoot()
            let strings = try localizedStrings(language: "en", root: root)
            let sentenceStyleKeys = [
                "oobe.done",
                "oobe.perm.heading",
                "oobe.trigger.heading",
                "oobe.engine.heading",
                "oobe.engine.sherpa.title",
            ]

            for key in sentenceStyleKeys {
                let value = try requiredString(key, in: strings, language: "en")
                let unexpectedTitleCaseWords = titleCaseWords(in: value).filter { word in
                    !isAllowedCapitalizedWord(word)
                }
                try expect(
                    unexpectedTitleCaseWords.isEmpty,
                    "\(key) should use sentence-style capitalization: \(value)"
                )
            }
        }

        await runner.run("OOBE headphone card localized copy fits fixed card budget") {
            let root = try repositoryRoot()
            let availableWidth = OOBEHeadphoneControlCardLayout.bodyTextWidth
            let fixedVerticalSpace = OOBEHeadphoneControlCardLayout.topPadding
                + 28
                + 12
                + 6
                + 12
                + 14
                + 1
                + 12
                + OOBEHeadphoneControlCardLayout.bottomPadding
            let cardHeight = OOBEHeadphoneControlCardLayout.cardHeight

            for language in languages {
                let strings = try localizedStrings(language: language, root: root)
                let title = try requiredString("oobe.trigger.headphone.title", in: strings, language: language)
                let desc = try requiredString("oobe.trigger.headphone.desc", in: strings, language: language)
                let hold = try requiredString("oobe.trigger.headphone.mode.hold", in: strings, language: language)
                let tap = try requiredString("oobe.trigger.headphone.mode.tap", in: strings, language: language)
                let enable = try requiredString("oobe.trigger.headphone.enable", in: strings, language: language)

                let titleHeight = cappedTextHeight(title, font: .systemFont(ofSize: 15, weight: .semibold), width: availableWidth, maxLines: 1)
                let descHeight = cappedTextHeight(desc, font: .systemFont(ofSize: 11.5), width: availableWidth, maxLines: 4)
                let modeHeight = max(
                    cappedTextHeight(hold, font: .systemFont(ofSize: 11), width: availableWidth, maxLines: 4),
                    cappedTextHeight(tap, font: .systemFont(ofSize: 11), width: availableWidth, maxLines: 4)
                )
                let toggleHeight = max(
                    CGFloat(22),
                    cappedTextHeight(enable, font: .systemFont(ofSize: 13), width: availableWidth - 26, maxLines: 2)
                )

                let requiredHeight = fixedVerticalSpace + titleHeight + descHeight + modeHeight + toggleHeight
                try expect(
                    requiredHeight <= cardHeight,
                    "\(language) OOBE headphone card requires \(requiredHeight)px, budget is \(cardHeight)px"
                )
            }
        }

        await runner.run("OOBE trigger key step columns fit content width") {
            let contentWidth = CGFloat(760 - 28 * 2)
            let rowWidth = OOBETriggerKeyStepLayout.leftColumnWidth
                + 18
                + OOBEHeadphoneControlCardLayout.cardWidth
            try expect(
                rowWidth <= contentWidth,
                "OOBE trigger key row requires \(rowWidth)px, budget is \(contentWidth)px"
            )
        }
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw TestFailure(file: #filePath, line: #line, message: "could not locate repository root")
    }

    private static func localizedStrings(language: String, root: URL) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        guard let strings = NSDictionary(contentsOf: url) as? [String: String] else {
            throw TestFailure(file: #filePath, line: #line, message: "could not load \(url.path)")
        }
        return strings
    }

    private static func requiredString(_ key: String, in strings: [String: String], language: String) throws -> String {
        guard let value = strings[key], !value.isEmpty else {
            throw TestFailure(file: #filePath, line: #line, message: "\(language) missing \(key)")
        }
        return value
    }

    private static func cappedTextHeight(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let naturalRect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.boundingRectForFont.height)
        return min(ceil(naturalRect.height), lineHeight * CGFloat(maxLines))
    }

    private static func titleCaseWords(in text: String) -> [String] {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        return words.dropFirst().compactMap { rawWord in
            let word = String(rawWord)
            guard let first = word.first, first.isUppercase else { return nil }
            return word
        }
    }

    private static func isAllowedCapitalizedWord(_ word: String) -> Bool {
        let allowed = ["AtomVoice", "Apple", "Doubao", "Mac", "API", "Return", "Bluetooth", "System", "Settings"]
        return allowed.contains(word) || word.allSatisfy { $0.isUppercase || $0.isNumber }
    }
}
