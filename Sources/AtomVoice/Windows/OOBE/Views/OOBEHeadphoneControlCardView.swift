import Cocoa

// MARK: - OOBE Headphone Control Card

enum OOBEHeadphoneControlCardLayout {
    static let cardWidth: CGFloat = 280
    static let cardHeight: CGFloat = 270
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 16
    static let bodyTextWidth: CGFloat = cardWidth - horizontalPadding * 2
}

final class OOBEHeadphoneControlCardView: NSView {
    var onToggle: ((Bool) -> Void)?

    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modeLabel = NSTextField(labelWithString: "")
    private var isEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = (isEnabled ? NSColor.controlAccentColor : NSColor.clear).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: loc("oobe.trigger.headphone.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        let desc = NSTextField(labelWithString: loc("oobe.trigger.headphone.desc"))
        desc.font = .systemFont(ofSize: 11.5)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byWordWrapping
        desc.maximumNumberOfLines = 4
        desc.preferredMaxLayoutWidth = OOBEHeadphoneControlCardLayout.bodyTextWidth

        modeLabel.font = .systemFont(ofSize: 11)
        modeLabel.textColor = .tertiaryLabelColor
        modeLabel.lineBreakMode = .byWordWrapping
        modeLabel.maximumNumberOfLines = 4
        modeLabel.preferredMaxLayoutWidth = OOBEHeadphoneControlCardLayout.bodyTextWidth

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        toggle.title = ""
        toggle.target = self
        toggle.action = #selector(toggleChanged)

        let toggleLabel = NSTextField(labelWithString: loc("oobe.trigger.headphone.enable"))
        toggleLabel.font = .systemFont(ofSize: 13)
        toggleLabel.textColor = .labelColor
        toggleLabel.lineBreakMode = .byWordWrapping
        toggleLabel.maximumNumberOfLines = 2
        toggleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggleRow = NSStackView(views: [toggle, toggleLabel])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.spacing = 6
        toggleRow.translatesAutoresizingMaskIntoConstraints = false
        toggleRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(icon)
        v.setCustomSpacing(12, after: icon)
        v.addArrangedSubview(title)
        v.setCustomSpacing(6, after: title)
        v.addArrangedSubview(desc)
        v.setCustomSpacing(12, after: desc)
        v.addArrangedSubview(modeLabel)
        v.setCustomSpacing(14, after: modeLabel)
        v.addArrangedSubview(divider)
        v.setCustomSpacing(12, after: divider)
        v.addArrangedSubview(toggleRow)

        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: OOBEHeadphoneControlCardLayout.topPadding),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OOBEHeadphoneControlCardLayout.horizontalPadding),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OOBEHeadphoneControlCardLayout.horizontalPadding),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OOBEHeadphoneControlCardLayout.bottomPadding),
        ])
        desc.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        modeLabel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        toggleLabel.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -26).isActive = true

        updateModeDescription(selectedSilenceAutoStop: AppSettings.silenceAutoStopEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        toggle.state = enabled ? .on : .off
        needsDisplay = true
    }

    func updateModeDescription(selectedSilenceAutoStop: Bool) {
        modeLabel.stringValue = selectedSilenceAutoStop
            ? loc("oobe.trigger.headphone.mode.tap")
            : loc("oobe.trigger.headphone.mode.hold")
    }

    @objc private func toggleChanged() {
        setEnabled(toggle.state == .on)
        onToggle?(isEnabled)
    }

    override func resetCursorRects() {}
}
