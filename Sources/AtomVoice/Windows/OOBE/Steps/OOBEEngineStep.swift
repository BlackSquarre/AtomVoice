import Cocoa

final class OOBEEngineStep: OOBEStep {
    private unowned let state: OOBESelectionState
    private var engineCardViews: [EngineCardView] = []

    init(state: OOBESelectionState) {
        self.state = state
    }

    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.engine.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let sub = NSTextField(labelWithString: loc("oobe.engine.subtitle"))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(20, after: sub)

        // 三张卡片：从左到右 → 隐私由高到低
        // (Three cards: left-to-right = privacy high → low)
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false

        engineCardViews = []
        let entries: [EngineCardModel] = [
            EngineCardModel(
                code: ASREngineRegistry.sherpaCode,
                title: loc("oobe.engine.sherpa.title"),
                tagline: loc("oobe.engine.sherpa.tagline"),
                iconName: "lock.shield.fill",
                iconColor: NSColor.systemGreen,
                badge: nil,
                privacyLevel: .high,
                privacyText: loc("oobe.engine.privacy.high"),
                qualityStars: 3,
                qualityText: loc("oobe.engine.quality.fair"),
                costStyle: .free,
                costText: loc("oobe.engine.cost.free"),
                costFootnote: loc("oobe.engine.cost.localNote"),
                desc: loc("oobe.engine.sherpa.desc")
            ),
            EngineCardModel(
                code: ASREngineRegistry.appleCode,
                title: loc("oobe.engine.apple.title"),
                tagline: loc("oobe.engine.apple.tagline"),
                iconName: "apple.logo",
                iconColor: NSColor.labelColor,
                badge: nil,
                privacyLevel: .medium,
                privacyText: loc("oobe.engine.privacy.medium"),
                qualityStars: 4,
                qualityText: loc("oobe.engine.quality.good"),
                costStyle: .free,
                costText: loc("oobe.engine.cost.free"),
                costFootnote: nil,
                desc: loc("oobe.engine.apple.desc")
            ),
            EngineCardModel(
                code: VolcengineASRSettings.engineCode,
                title: loc("oobe.engine.doubao.title"),
                tagline: loc("oobe.engine.doubao.tagline"),
                iconName: "cloud.fill",
                iconColor: NSColor.systemBlue,
                badge: nil,
                privacyLevel: .low,
                privacyText: loc("oobe.engine.privacy.low"),
                qualityStars: 5,
                qualityText: loc("oobe.engine.quality.best"),
                costStyle: .paid,
                costText: loc("oobe.engine.cost.paid"),
                costFootnote: nil,
                desc: loc("oobe.engine.doubao.desc")
            ),
        ]
        for model in entries {
            let card = EngineCardView(model: model)
            card.onSelect = { [weak self] code in self?.engineSelected(code) }
            cards.addArrangedSubview(card)
            engineCardViews.append(card)
        }
        v.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

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
    }

}
