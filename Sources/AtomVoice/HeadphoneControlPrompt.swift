import Cocoa

/// 耳机语音控制启用确认提示。
/// 使用原生 NSAlert 外壳，只定制正文排版以突出主次。
enum HeadphoneControlPrompt {
    static func requestEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = loc("alert.headphoneControl.title")
        alert.icon = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        alert.accessoryView = makeAccessoryView(message: loc("alert.headphoneControl.message"))
        alert.addButton(withTitle: loc("alert.headphoneControl.enable"))
        alert.addButton(withTitle: loc("common.cancel"))
        return AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn
    }

    private static func makeAccessoryView(message: String) -> NSView {
        let width: CGFloat = 360
        let messageParts = Self.messageParts(from: message)

        let body = NSTextField(wrappingLabelWithString: messageParts.body)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        let bodyHeight = textHeight(messageParts.body, font: body.font!, width: width)
        body.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)

        let spacing: CGFloat = messageParts.note.isEmpty ? 0 : 10
        let noteHeight = messageParts.note.isEmpty ? 0 : textHeight(
            messageParts.note,
            font: .systemFont(ofSize: 12),
            width: width - 41
        ) + 16
        let totalHeight = ceil(bodyHeight + spacing + noteHeight)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
        body.frame.origin.y = totalHeight - bodyHeight
        container.addSubview(body)

        if !messageParts.note.isEmpty {
            let note = makeNoteView(text: messageParts.note, frame: NSRect(x: 0, y: 0, width: width, height: noteHeight))
            container.addSubview(note)
        }
        return container
    }

    private static func makeNoteView(text: String, frame: NSRect) -> NSView {
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        icon.frame = NSRect(x: 10, y: frame.height - 24, width: 14, height: 14)
        container.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.frame = NSRect(x: 31, y: 8, width: frame.width - 41, height: frame.height - 16)
        container.addSubview(label)

        return container
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
        return ceil(rect.height) + 2
    }

    private static func messageParts(from message: String) -> (body: String, note: String) {
        let sentences = splitSentences(message)
        guard sentences.count > 2 else {
            return (message, "")
        }
        let body = sentences.dropLast(2).joined(separator: " ")
        let note = sentences.suffix(2).joined(separator: " ")
        return (body, note)
    }

    private static func splitSentences(_ message: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in message {
            current.append(character)
            if ".。！？!?".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences.isEmpty ? [message] : sentences
    }
}
