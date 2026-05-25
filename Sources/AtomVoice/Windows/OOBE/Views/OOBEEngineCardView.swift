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
    let qualityStars: Int   // 1...5
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

        // 顶部图标（Top icon）
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        iconView.contentTintColor = model.iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // 标题行（Title row with optional badge）
        let titleLabel = NSTextField(labelWithString: model.title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(titleLabel)
        if let badgeText = model.badge {
            titleRow.addArrangedSubview(makeBadge(text: badgeText))
        }

        // 副标题（Tagline — one-liner positioning）
        let tagline = NSTextField(labelWithString: model.tagline)
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 2

        // 属性区：隐私 + 费用各一行；星级单独一行（更大、视觉重点）
        // (Attributes: privacy + cost as inline rows; stars get a dedicated larger row)
        let privacyRow = makeInlineAttrRow(
            icon: makePrivacyDot(level: model.privacyLevel),
            text: model.privacyText,
            textColor: .labelColor
        )
        let costIconName: String
        let costColor: NSColor
        switch model.costStyle {
        case .free:
            costIconName = "checkmark.seal.fill"
            costColor = NSColor.systemGreen
        case .paid:
            costIconName = "creditcard.fill"
            costColor = NSColor.systemOrange
        }
        let costIcon = NSImageView()
        costIcon.image = NSImage(systemSymbolName: costIconName, accessibilityDescription: nil)
        costIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        costIcon.contentTintColor = costColor
        let costRow = makeInlineAttrRow(
            icon: costIcon,
            text: model.costText,
            textColor: costColor,
            footnote: model.costFootnote
        )

        // 星级单独一行（Stars on a dedicated row, larger）
        let starsView = makeStars(filled: model.qualityStars, pointSize: 16)
        let qualityLabel = NSTextField(labelWithString: model.qualityText)
        qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        qualityLabel.textColor = .secondaryLabelColor
        let qualityRow = NSStackView(views: [starsView, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualityRow.alignment = .centerY

        let attrStack = NSStackView()
        attrStack.orientation = .vertical
        attrStack.alignment = .leading
        attrStack.spacing = 10
        attrStack.addArrangedSubview(privacyRow)
        attrStack.addArrangedSubview(costRow)
        attrStack.setCustomSpacing(14, after: costRow)
        attrStack.addArrangedSubview(qualityRow)

        // 描述（Description）
        let descLabel = NSTextField(labelWithString: model.desc)
        descLabel.font = .systemFont(ofSize: 11.5)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(iconView)
        v.setCustomSpacing(12, after: iconView)
        v.addArrangedSubview(titleRow)
        v.setCustomSpacing(4, after: titleRow)
        v.addArrangedSubview(tagline)
        v.setCustomSpacing(18, after: tagline)
        v.addArrangedSubview(attrStack)
        v.setCustomSpacing(18, after: attrStack)
        // 分隔线 + 描述（Separator + description）
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(sep)
        v.setCustomSpacing(12, after: sep)
        v.addArrangedSubview(descLabel)

        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            v.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
        tagline.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        descLabel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        sep.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        addGestureRecognizer(click)
    }

    /// 内联属性行：图标 + 主文本 + 可选灰色副本
    /// (Inline attribute row: icon + main text + optional grey footnote)
    private func makeInlineAttrRow(icon: NSView, text: String, textColor: NSColor, footnote: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        // 统一图标容器尺寸，确保每行图标高度一致，使 .centerY 对齐稳定
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

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(iconContainer)
        row.addArrangedSubview(label)

        if let footnote = footnote, !footnote.isEmpty {
            let note = NSTextField(labelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
            row.addArrangedSubview(note)
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
        onSelect?(code)
    }

    func setSelected(_ value: Bool) {
        selected = value
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
