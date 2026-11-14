import Cocoa

// MARK: - Engine Card

struct EngineCardModel {
    enum PrivacyLevel { case high, medium, low }
    /// 费用样式枚举，决定图标和颜色（Cost style: drives icon + color）
    enum CostStyle {
        case free            // 免费 → 绿色 ✓（包含本地离线"免费但需下载模型"）
        case paid            // 付费 → 橙色 信用卡
    }

    let code: String
    let title: String
    let tagline: String
    let iconName: String
    let iconColor: NSColor
    let badge: String?
    let privacyLevel: PrivacyLevel
    let privacyText: String
    let qualityStars: Int?   // 未验收的引擎不虚构星级。
    let qualityText: String
    let costStyle: CostStyle
    let costText: String
    /// 副注：例如本地离线"需下载模型"，灰色显示在主文之后
    /// (Footnote, e.g. "Model download" — shown in grey after main cost text)
    let costFootnote: String?
    let desc: String
}

final class EngineCardView: NSView {
    let code: String
    var onSelect: ((String) -> Void)?
    private var selected = false
    private let model: EngineCardModel

    init(model: EngineCardModel) {
        self.code = model.code
        self.model = model
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.clear).cgColor
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
        focusRingType = .exterior
        identifier = NSUserInterfaceItemIdentifier("oobe.engine.card.\(code)")
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel([model.title, model.privacyText, model.costText, model.costFootnote, model.qualityText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        iconView.contentTintColor = model.iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = makeWrappingLabel(model.title, font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor, width: 143)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("oobe.engine.card.title")
        let titleRow = NSStackView(views: [titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.heightAnchor.constraint(equalToConstant: 40).isActive = true
        if let badgeText = model.badge {
            titleRow.addArrangedSubview(makeBadge(text: badgeText))
        } else {
            titleLabel.widthAnchor.constraint(equalTo: titleRow.widthAnchor).isActive = true
        }

        let privacyRow = makeInlineAttrRow(
            icon: makePrivacyDot(level: model.privacyLevel),
            text: model.privacyText,
            textColor: .labelColor
        )
        privacyRow.identifier = NSUserInterfaceItemIdentifier("oobe.engine.card.privacy")
        privacyRow.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let costIcon = NSImageView()
        let costColor: NSColor
        switch model.costStyle {
        case .free:
            costIcon.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)
            costColor = .systemGreen
        case .paid:
            costIcon.image = NSImage(systemSymbolName: "creditcard.fill", accessibilityDescription: nil)
            costColor = .systemOrange
        }
        costIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        costIcon.contentTintColor = costColor
        let costRow = makeInlineAttrRow(icon: costIcon, text: model.costText, textColor: costColor,
                                       footnote: model.costFootnote)
        costRow.identifier = NSUserInterfaceItemIdentifier("oobe.engine.card.cost")
        costRow.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(iconView)
        content.setCustomSpacing(8, after: iconView)
        content.addArrangedSubview(titleRow)
        content.setCustomSpacing(10, after: titleRow)
        content.addArrangedSubview(privacyRow)
        content.setCustomSpacing(6, after: privacyRow)
        content.addArrangedSubview(costRow)

        if let stars = model.qualityStars {
            let starsView = makeStars(filled: stars, pointSize: 14)
            let qualityLabel = makeWrappingLabel(model.qualityText, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor, width: 143)
            let quality = NSStackView(views: [starsView, qualityLabel])
            quality.orientation = .vertical
            quality.alignment = .leading
            quality.spacing = 2
            quality.identifier = NSUserInterfaceItemIdentifier("oobe.engine.card.quality")
            quality.setAccessibilityValue(stars)
            content.setCustomSpacing(10, after: costRow)
            content.addArrangedSubview(quality)
            quality.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            qualityLabel.widthAnchor.constraint(equalTo: quality.widthAnchor).isActive = true
        }

        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            titleRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            privacyRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            costRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        addGestureRecognizer(click)
    }

    private func makeWrappingLabel(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    /// 长属性完整换行；下载副注另占一行，不在167pt卡片内与主文争宽。
    private func makeInlineAttrRow(icon: NSView, text: String, textColor: NSColor, footnote: String? = nil) -> NSView {
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])

        let label = makeWrappingLabel(text, font: .systemFont(ofSize: 12, weight: .medium), color: textColor, width: 121)
        let main = NSStackView(views: [iconContainer, label])
        main.orientation = .horizontal
        main.spacing = 6
        main.alignment = .top
        main.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [main])
        row.orientation = .vertical
        row.alignment = .leading
        row.distribution = .fill
        row.spacing = 3
        main.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        if let footnote, !footnote.isEmpty {
            let note = makeWrappingLabel(footnote, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, width: 143)
            row.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        return row
    }

    private func makePrivacyDot(level: EngineCardModel.PrivacyLevel) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.cornerCurve = .circular
        let color: NSColor
        switch level {
        case .high:   color = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)  // 🟢
        case .medium: color = NSColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1)  // 🟡
        case .low:    color = NSColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1)  // 🔴
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        // 内圆点 12×12，交给外层容器居中（makeInlineAttrRow 统一包 16×16 容器）
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return dot
    }

    private func makeStars(filled: Int, pointSize: CGFloat = 10) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        for i in 0..<5 {
            let star = NSImageView()
            let symbol = (i < filled) ? "star.fill" : "star"
            star.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            star.symbolConfiguration = .init(pointSize: pointSize, weight: .medium)
            star.contentTintColor = (i < filled)
                ? NSColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1)
                : .quaternaryLabelColor
            row.addArrangedSubview(star)
        }
        return row
    }

    private func makeBadge(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.cornerCurve = .continuous
        bg.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
        ])
        return bg
    }

    @objc private func cardClicked() {
        window?.makeFirstResponder(self)
        onSelect?(code)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, event.charactersIgnoringModifiers == " " {
            onSelect?(code)
        } else if modifiers.isEmpty, event.keyCode == 48 {
            // Tab沿用窗口既有焦点顺序，Return仍由原继续按钮处理。
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else {
            super.keyDown(with: event)
        }
    }

    func setSelected(_ value: Bool) {
        selected = value
        setAccessibilityValue(value)
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(code)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
