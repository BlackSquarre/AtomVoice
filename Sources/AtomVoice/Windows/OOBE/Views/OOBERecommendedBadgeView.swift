import Cocoa

// MARK: - 推荐徽标视图（Recommended badge pill used next to OOBE controls）

final class OOBERecommendedBadgeView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        // 白底蓝字：选中（蓝色分段）和未选中（灰色分段）背景下都能看清
        // (White background + accent text stays legible on both selected and unselected segments)
        layer?.backgroundColor = NSColor.white.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
