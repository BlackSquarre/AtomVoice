import Cocoa

final class OOBEDoneStep: OOBEStep {
    private unowned let state: OOBESelectionState

    init(state: OOBESelectionState) {
        self.state = state
    }

    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 14

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 64, weight: .regular)
        check.contentTintColor = NSColor(red: 0.15, green: 0.78, blue: 0.33, alpha: 1)

        let title = NSTextField(labelWithString: loc("oobe.done.title"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .center

        // 按选中触发键动态生成引导文案（Build body using selected trigger key）
        let opt = TriggerKeyOption.option(for: state.triggerKeyCode)
        let bodyLocKey = state.silenceAutoStop ? "oobe.done.body.tap" : "oobe.done.body"
        let bodyText = String(format: loc(bodyLocKey), loc(opt.symbolKey))

        let font = NSFont.systemFont(ofSize: 13)
        let attrString = NSMutableAttributedString(string: bodyText, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        attrString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attrString.length))

        if let iconRange = bodyText.range(of: "(ICON)") {
            let nsRange = NSRange(iconRange, in: bodyText)
            var image: NSImage?
            if let url = Bundle.main.url(forResource: "atomvoice-status", withExtension: "svg", subdirectory: "Icons") {
                image = NSImage(contentsOf: url)
            } else {
                image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            }
            image?.isTemplate = true

            let attachment = NSTextAttachment()
            if let img = image {
                let size = NSSize(width: 15, height: 15)
                img.size = size

                let tintedImg = NSImage(size: size)
                tintedImg.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: size))
                NSColor.secondaryLabelColor.set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
                tintedImg.unlockFocus()

                attachment.image = tintedImg
                attachment.bounds = NSRect(x: 0, y: font.descender, width: 15, height: 15)
            }

            let attachString = NSMutableAttributedString(attachment: attachment)
            attachString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: attachString.length))
            attrString.replaceCharacters(in: nsRange, with: attachString)
        }

        let body = NSTextField(labelWithAttributedString: attrString)
        body.maximumNumberOfLines = 0
        body.preferredMaxLayoutWidth = 540

        let nextStepText: String
        switch state.engine {
        case VolcengineASRSettings.engineCode:
            nextStepText = loc("oobe.done.followup.doubao")
        case ASREngineRegistry.sherpaCode:
            nextStepText = loc("oobe.done.followup.sherpa")
        default:
            nextStepText = loc("oobe.done.followup.apple")
        }
        let followup = NSTextField(labelWithString: nextStepText)
        followup.font = .systemFont(ofSize: 12)
        followup.textColor = .tertiaryLabelColor
        followup.alignment = .center
        followup.lineBreakMode = .byWordWrapping
        followup.maximumNumberOfLines = 0
        followup.preferredMaxLayoutWidth = 540

        let topSpacer = NSView()
        let botSpacer = NSView()
        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(check)
        v.setCustomSpacing(16, after: check)
        v.addArrangedSubview(title)
        v.setCustomSpacing(8, after: title)
        v.addArrangedSubview(body)
        v.setCustomSpacing(20, after: body)
        v.addArrangedSubview(followup)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true

        return v
    }
}
