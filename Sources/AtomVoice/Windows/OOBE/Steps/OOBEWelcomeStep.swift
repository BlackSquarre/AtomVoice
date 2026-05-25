import Cocoa

final class OOBEWelcomeStep: OOBEStep {
    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 14

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: loc("oobe.welcome.title"))
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        // 主 Tagline：核心 slogan，比副标更显眼（Primary tagline — louder than subtitle）
        let tagline = NSTextField(labelWithString: loc("oobe.welcome.tagline"))
        tagline.font = .systemFont(ofSize: 16, weight: .medium)
        tagline.textColor = .labelColor
        tagline.alignment = .center
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 540

        let subtitle = NSTextField(labelWithString: loc("oobe.welcome.subtitle"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = 540

        let hint = NSTextField(labelWithString: loc("oobe.welcome.hint"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let topSpacer = NSView()
        let botSpacer = NSView()

        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(icon)
        v.setCustomSpacing(20, after: icon)
        v.addArrangedSubview(title)
        v.setCustomSpacing(6, after: title)
        v.addArrangedSubview(tagline)
        v.setCustomSpacing(64, after: tagline)
        v.addArrangedSubview(subtitle)
        v.setCustomSpacing(8, after: subtitle)
        v.addArrangedSubview(hint)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true

        return v
    }
}
