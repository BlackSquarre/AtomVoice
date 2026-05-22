import Cocoa

enum HelpAlertPresenter {
    static func showEngineHowto() {
        let alert = NSAlert()
        alert.messageText = loc("menu.engine.howto")
        alert.icon = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        alert.accessoryView = makeTextView(
            text: loc("engine.howto.message"),
            width: 660,
            height: 430,
            attributedString: makeEngineHowtoAttributedString
        )
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

    static func showLLMHowto() {
        let alert = NSAlert()
        alert.messageText = loc("menu.llm.howto")
        alert.icon = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        alert.accessoryView = makeTextView(
            text: loc("llm.howto.message"),
            width: 560,
            height: 380,
            attributedString: makeLLMHowtoAttributedString
        )
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

    private static func makeTextView(
        text: String,
        width: CGFloat,
        height: CGFloat,
        attributedString: (String) -> NSAttributedString
    ) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 32, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedString(text))

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(usedHeight)))
        }

        scrollView.documentView = textView
        return scrollView
    }

    private static func makeEngineHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingParagraph = paragraph(lineSpacing: 2, paragraphSpacing: 6)
        let bodyParagraph = paragraph(lineSpacing: 3, paragraphSpacing: 7)
        let summaryParagraph = paragraph(lineSpacing: 3, paragraphSpacing: 0)

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let summaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: summaryParagraph,
        ]

        let summaryPrefixes = ["建议", "建議", "Recommendation", "おすすめ", "추천", "Recomendación", "Recommandation", "Empfehlung"]
        appendFormattedLines(to: result, lines: lines) { line in
            if line.hasPrefix("• ") { return headingAttributes }
            if summaryPrefixes.contains(where: { line.hasPrefix($0) }) { return summaryAttributes }
            return bodyAttributes
        }
        return result
    }

    private static func makeLLMHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph(lineSpacing: 2, paragraphSpacing: 6),
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph(lineSpacing: 3, paragraphSpacing: 7),
        ]
        let listParagraph = paragraph(lineSpacing: 3, paragraphSpacing: 4)
        listParagraph.headIndent = 20
        listParagraph.firstLineHeadIndent = 0
        let listAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: listParagraph,
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph(lineSpacing: 3, paragraphSpacing: 0),
        ]

        let headingPrefixes = ["LLM", "例如", "使用方法", "For example", "How to use", "例", "使い方", "예", "사용 방법"]
        let notePrefixes = ["开启后", "When enabled", "有効にすると", "활성화하면"]
        appendFormattedLines(to: result, lines: lines) { line in
            if headingPrefixes.contains(where: { line.hasPrefix($0) }) { return headingAttributes }
            if notePrefixes.contains(where: { line.hasPrefix($0) }) { return noteAttributes }
            if line.hasPrefix("1.") || line.hasPrefix("2.") || line.hasPrefix("3.") || line.hasPrefix("4.") { return listAttributes }
            return bodyAttributes
        }
        return result
    }

    private static func paragraph(lineSpacing: CGFloat, paragraphSpacing: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    private static func appendFormattedLines(
        to result: NSMutableAttributedString,
        lines: [String],
        attributesForLine: (String) -> [NSAttributedString.Key: Any]
    ) {
        var previousLineWasBlank = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousLineWasBlank, result.length > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                previousLineWasBlank = true
                continue
            }
            result.append(NSAttributedString(string: line + "\n", attributes: attributesForLine(line)))
            previousLineWasBlank = false
        }
    }
}
