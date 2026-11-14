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

        await runner.run("OOBE four engine cards and complete selected copy fit in all eight languages") {
            let root = try repositoryRoot()
            for language in languages {
                let strings = try localizedStrings(language: language, root: root)
                try await MainActor.run {
                    let state = OOBESelectionState()
                    state.engine = OpenAIASRSettings.engineCode
                    let step = OOBEEngineStep(state: state, localize: { strings[$0] ?? $0 })
                    defer { withExtendedLifetime(step) {} }
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 704, height: 426))
                    let page = step.makeView()
                    page.translatesAutoresizingMaskIntoConstraints = false
                    host.addSubview(page)
                    NSLayoutConstraint.activate([
                        page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        page.topAnchor.constraint(equalTo: host.topAnchor),
                        page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutSubtreeIfNeeded()

                    let codes = [ASREngineRegistry.sherpaCode, ASREngineRegistry.appleCode,
                                 VolcengineASRSettings.engineCode, OpenAIASRSettings.engineCode]
                    let cards = descendants(page).compactMap { $0 as? EngineCardView }
                    try expect(cards.map(\.code) == codes, "\(language): all four engines must stay in their original order")
                    let frames = cards.map { alignmentFrame($0, in: host) }
                    for (index, frame) in frames.enumerated() {
                        try expect(approximatelyEqual(frame.width, 167, tolerance: 1), "\(language): card \(index) frame \(frame)")
                        try expect(approximatelyEqual(frame.height, 244, tolerance: 1), "\(language): card \(index) frame \(frame)")
                        try expect(host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(language): card \(index) must remain visible: \(frame)")
                        if index > 0 {
                            try expect(approximatelyEqual(frame.minX - frames[index - 1].maxX, 12, tolerance: 1), "\(language): cards cannot overlap or hide the fourth choice")
                        }
                        for label in descendants(cards[index]).compactMap({ $0 as? NSTextField }) {
                            try expectCompleteLabel(label, in: host, language: language)
                            let localFrame = alignmentFrame(label, in: cards[index])
                            try expect(cards[index].bounds.insetBy(dx: -1, dy: -1).contains(localFrame), "\(language): text escaped its card: \(localFrame)")
                        }
                    }

                    let description = try require(descendants(page).first { $0.identifier?.rawValue == "oobe.engine.detail.description" } as? NSTextField)
                    let tagline = try require(descendants(page).first { $0.identifier?.rawValue == "oobe.engine.detail.tagline" } as? NSTextField)
                    let copyKeys = ["sherpa", "apple", "doubao", "openai"]
                    var largestDescriptionHeight: CGFloat = 0
                    for (index, card) in cards.enumerated() {
                        try expect(card.accessibilityPerformPress())
                        host.layoutSubtreeIfNeeded()
                        try expect(state.engine == card.code)
                        try expect((card.accessibilityValue() as? Bool) == true)
                        let original = try requiredString("oobe.engine.\(copyKeys[index]).desc", in: strings, language: language)
                        let words = { (text: String) in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                        try expect(words(description.stringValue) == words(original), "\(language): selected description must keep all original words")
                        try expect(tagline.stringValue == strings["oobe.engine.\(copyKeys[index]).tagline"])
                        try expectCompleteLabel(tagline, in: host, language: language)
                        try expectCompleteLabel(description, in: host, language: language)
                        let detailFrame = alignmentFrame(description, in: host)
                        try expect(approximatelyEqual(detailFrame.width, 704, tolerance: 1))
                        try expect(detailFrame.maxY <= frames[0].minY + 1, "\(language): full copy must remain below all four cards")
                        largestDescriptionHeight = max(largestDescriptionHeight, detailFrame.height)
                    }
                    print("OOBE engine frames [\(language)]: \(frames); maximum description height=\(largestDescriptionHeight)")
                }
            }
        }

        await runner.run("OOBE engine summary retains legacy ratings and leaves OpenAI unrated") {
            try await MainActor.run {
                let state = OOBESelectionState()
                let step = OOBEEngineStep(state: state)
                let view = step.makeView()
                let cards = descendants(view).compactMap { $0 as? EngineCardView }
                try expect(cards.count == 4)
                for (index, card) in cards.enumerated() {
                    let quality = descendants(card).first { $0.identifier?.rawValue == "oobe.engine.card.quality" }
                    if index < 3 {
                        try expect((quality?.accessibilityValue() as? Int) == index + 3)
                    } else {
                        try expect(quality == nil, "OpenAI must not acquire a fabricated rating during layout changes")
                    }
                }
            }
        }

        await runner.run("OOBE engine cards keep keyboard focus and Space selection") {
            try await MainActor.run {
                let state = OOBESelectionState()
                state.engine = ASREngineRegistry.appleCode
                let step = OOBEEngineStep(state: state)
                defer { withExtendedLifetime(step) {} }
                let page = step.makeView()
                let cards = descendants(page).compactMap { $0 as? EngineCardView }
                let openAI = try require(cards.first { $0.code == OpenAIASRSettings.engineCode })
                let apple = try require(cards.first { $0.code == ASREngineRegistry.appleCode })
                try expect(cards.allSatisfy(\.acceptsFirstResponder))
                openAI.setFrameSize(NSSize(width: 167, height: 244))
                try expect(openAI.focusRingType == .exterior && openAI.focusRingMaskBounds == openAI.bounds)
                try expect(!openAI.focusRingMaskBounds.isEmpty)
                let space = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49))
                openAI.keyDown(with: space)
                try expect(state.engine == OpenAIASRSettings.engineCode)
                try expect((openAI.accessibilityValue() as? Bool) == true)
                try expect((apple.accessibilityValue() as? Bool) == false)
                try expect(apple.accessibilityPerformPress())
                try expect(state.engine == ASREngineRegistry.appleCode)
            }
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func expectCompleteLabel(_ label: NSTextField, in host: NSView, language: String) throws {
        let frame = alignmentFrame(label, in: host)
        let required = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1_000)).height ?? 0
        try expect(required <= label.bounds.height + 1, "\(language): text clipped at \(frame), requires \(required): \(label.stringValue)")
        try expect(host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(language): label escaped fixed content area: \(frame)")
        try expect(label.maximumNumberOfLines == 0 && label.lineBreakMode == .byWordWrapping)
    }

    private static func alignmentFrame(_ view: NSView, in target: NSView) -> NSRect {
        guard let parent = view.superview else { return view.convert(view.bounds, to: target) }
        // 原生文字框的frame含绘制留白，布局边界应比较其可见对齐矩形。
        return parent.convert(view.alignmentRect(forFrame: view.frame), to: target)
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
