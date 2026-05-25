import Cocoa

// MARK: - OOBE Permission Card (vertical layout matching engine cards)
// 权限页竖版卡片：与引擎卡风格一致，顶部彩色图标 + 标题 + 描述 + 状态 + 操作按钮
// (Vertical permission card matching engine-card style: icon → title → desc → status → action)

final class OOBEPermissionCardView: NSView {
    private let titleLabel: NSTextField
    private let descLabel: NSTextField
    private let actionBtn: NSButton
    private let iconView: NSImageView
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentDotColor: NSColor = .systemGray

    init(title: String, desc: String, iconName: String, iconColor: NSColor,
         tag: Int, target: AnyObject, action: Selector) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.descLabel = NSTextField(labelWithString: desc)
        self.actionBtn = NSButton(title: "", target: target, action: action)
        self.iconView = NSImageView()
        super.init(frame: .zero)
        self.actionBtn.tag = tag
        self.iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        self.iconView.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        self.iconView.contentTintColor = iconColor
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            layer?.backgroundColor = bg.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        statusDot.layer?.backgroundColor = currentDotColor.cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        descLabel.font = .systemFont(ofSize: 11.5)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.cornerCurve = .circular
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        actionBtn.bezelStyle = .rounded
        actionBtn.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(iconView)
        v.setCustomSpacing(12, after: iconView)
        v.addArrangedSubview(titleLabel)
        v.setCustomSpacing(6, after: titleLabel)
        v.addArrangedSubview(descLabel)

        // 底部固定区：分隔线 + 状态 + 按钮（Bottom block: separator + status + button）
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(v)
        addSubview(sep)
        addSubview(statusRow)
        addSubview(actionBtn)
        descLabel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sep.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -12),

            statusRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusRow.bottomAnchor.constraint(equalTo: actionBtn.topAnchor, constant: -10),

            actionBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    func update(status: PermissionStatus) {
        currentDotColor = status.color
        statusDot.layer?.backgroundColor = status.color.cgColor
        statusLabel.stringValue = status.label
        statusLabel.textColor = status.color
        actionBtn.title = (status == .notDetermined)
            ? loc("permission.action.request")
            : loc("permission.action.open")
    }
}
