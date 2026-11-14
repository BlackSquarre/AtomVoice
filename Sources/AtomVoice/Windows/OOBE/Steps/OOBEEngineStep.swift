import Cocoa

final class OOBEEngineStep: NSObject, OOBEStep {
    private unowned let state: OOBESelectionState
    private var engineCardViews: [EngineCardView] = []
    private var models: [EngineCardModel] = []
    private let localize: (String) -> String
    private var detailTagline: NSTextField?
    private var detailDescription: NSTextField?

    init(state: OOBESelectionState, localize: @escaping (String) -> String = loc) {
        self.state = state
        self.localize = localize
        super.init()
    }

    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.distribution = .fill

        let heading = NSTextField(labelWithString: localize("oobe.engine.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let sub = NSTextField(labelWithString: localize("oobe.engine.subtitle"))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(14, after: sub)

        // 四张摘要卡始终并排，完整说明在下方使用整行宽度。
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false

        engineCardViews = []
        let entries: [EngineCardModel] = [
            EngineCardModel(
                code: ASREngineRegistry.sherpaCode,
                title: localize("oobe.engine.sherpa.title"),
                tagline: localize("oobe.engine.sherpa.tagline"),
                iconName: "lock.shield.fill",
                iconColor: NSColor.systemGreen,
                badge: nil,
                privacyLevel: .high,
                privacyText: localize("oobe.engine.privacy.high"),
                qualityStars: 3,
                qualityText: localize("oobe.engine.quality.fair"),
                costStyle: .free,
                costText: localize("oobe.engine.cost.free"),
                costFootnote: localize("oobe.engine.cost.localNote"),
                desc: localize("oobe.engine.sherpa.desc")
            ),
            EngineCardModel(
                code: ASREngineRegistry.appleCode,
                title: localize("oobe.engine.apple.title"),
                tagline: localize("oobe.engine.apple.tagline"),
                iconName: "apple.logo",
                iconColor: NSColor.labelColor,
                badge: nil,
                privacyLevel: .medium,
                privacyText: localize("oobe.engine.privacy.medium"),
                qualityStars: 4,
                qualityText: localize("oobe.engine.quality.good"),
                costStyle: .free,
                costText: localize("oobe.engine.cost.free"),
                costFootnote: nil,
                desc: localize("oobe.engine.apple.desc")
            ),
            EngineCardModel(
                code: VolcengineASRSettings.engineCode,
                title: localize("oobe.engine.doubao.title"),
                tagline: localize("oobe.engine.doubao.tagline"),
                iconName: "cloud.fill",
                iconColor: NSColor.systemBlue,
                badge: nil,
                privacyLevel: .low,
                privacyText: localize("oobe.engine.privacy.low"),
                qualityStars: 5,
                qualityText: localize("oobe.engine.quality.best"),
                costStyle: .paid,
                costText: localize("oobe.engine.cost.paid"),
                costFootnote: nil,
                desc: localize("oobe.engine.doubao.desc")
            ),
            EngineCardModel(
                code: OpenAIASRSettings.engineCode,
                title: localize("oobe.engine.openai.title"),
                tagline: localize("oobe.engine.openai.tagline"),
                iconName: "cloud.fill",
                iconColor: .systemTeal,
                badge: nil,
                privacyLevel: .low,
                privacyText: localize("oobe.engine.privacy.low"),
                qualityStars: nil,
                qualityText: "",
                costStyle: .paid,
                costText: localize("oobe.engine.cost.paid"),
                costFootnote: nil,
                desc: localize("oobe.engine.openai.desc")
            ),
        ]
        models = entries
        for model in entries {
            let card = EngineCardView(model: model)
            card.onSelect = { [weak self] code in self?.engineSelected(code) }
            cards.addArrangedSubview(card)
            card.heightAnchor.constraint(equalToConstant: 244).isActive = true
            engineCardViews.append(card)
        }
        v.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(12, after: cards)

        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .leading
        details.distribution = .fill
        details.spacing = 4
        details.identifier = NSUserInterfaceItemIdentifier("oobe.engine.details")
        let tagline = NSTextField(wrappingLabelWithString: "")
        tagline.font = .systemFont(ofSize: 12, weight: .medium)
        tagline.textColor = .labelColor
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 704
        tagline.identifier = NSUserInterfaceItemIdentifier("oobe.engine.detail.tagline")
        let description = NSTextField(wrappingLabelWithString: "")
        description.font = .systemFont(ofSize: 11.5)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.preferredMaxLayoutWidth = 704
        description.identifier = NSUserInterfaceItemIdentifier("oobe.engine.detail.description")
        details.addArrangedSubview(tagline)
        details.addArrangedSubview(description)
        v.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        tagline.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        description.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        detailTagline = tagline
        detailDescription = description

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.addArrangedSubview(spacer)

        applyEngineSelection()
        return v
    }

    private func engineSelected(_ code: String) {
        state.engine = code
        applyEngineSelection()
    }

    private func applyEngineSelection() {
        for card in engineCardViews {
            card.setSelected(card.code == state.engine)
        }
        guard let model = models.first(where: { $0.code == state.engine }) else { return }
        detailTagline?.stringValue = model.tagline
        // 只收紧旧文案的重复空行，保留所有字词和段落，避免窄卡挤压正文。
        let description = model.desc.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 4
        detailDescription?.attributedStringValue = NSAttributedString(string: description, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        detailTagline?.invalidateIntrinsicContentSize()
        detailDescription?.invalidateIntrinsicContentSize()
    }
}
