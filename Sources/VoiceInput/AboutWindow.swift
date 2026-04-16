import Cocoa

final class AboutWindowController: NSObject {
    private var window: NSWindow?

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        buildWindow()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "关于 VoiceInput"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = false

        guard let cv = w.contentView else { return }

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.alignment = .centerX
        vStack.spacing = 0
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 20, right: 20)
        cv.addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: cv.topAnchor),
            vStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            vStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        // ── App 图标 ───────────────────────────────────────────
        let iconView = NSImageView()
        if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            iconView.image = icon
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 80).isActive = true
        vStack.addArrangedSubview(iconView)
        vStack.setCustomSpacing(12, after: iconView)

        // ── 应用名称 ──────────────────────────────────────────
        let nameLabel = NSTextField(labelWithString: "VoiceInput")
        nameLabel.font = .boldSystemFont(ofSize: 18)
        nameLabel.textColor = .labelColor
        vStack.addArrangedSubview(nameLabel)
        vStack.setCustomSpacing(4, after: nameLabel)

        // ── 版本号 ────────────────────────────────────────────
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "版本 \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        vStack.addArrangedSubview(versionLabel)
        vStack.setCustomSpacing(20, after: versionLabel)

        // ── 分割线 ────────────────────────────────────────────
        let sep1 = makeSeparator()
        vStack.addArrangedSubview(sep1)
        sep1.widthAnchor.constraint(equalTo: vStack.widthAnchor, constant: -40).isActive = true
        vStack.setCustomSpacing(16, after: sep1)

        // ── 作者 ──────────────────────────────────────────────
        let authorLabel = NSTextField(labelWithString: "作者")
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .tertiaryLabelColor
        vStack.addArrangedSubview(authorLabel)
        vStack.setCustomSpacing(4, after: authorLabel)

        let authorName = NSTextField(labelWithString: "缪凌儒  BlackSquare")
        authorName.font = .systemFont(ofSize: 13, weight: .medium)
        authorName.textColor = .labelColor
        vStack.addArrangedSubview(authorName)
        vStack.setCustomSpacing(16, after: authorName)

        // ── 链接区 ────────────────────────────────────────────
        let linksStack = NSStackView()
        linksStack.orientation = .vertical
        linksStack.alignment = .leading
        linksStack.spacing = 8

        linksStack.addArrangedSubview(
            makeLinkRow(
                symbolName: "play.circle.fill",
                symbolColor: .systemPink,
                title: "Bilibili 主页",
                url: "https://space.bilibili.com/404899"
            )
        )
        linksStack.addArrangedSubview(
            makeLinkRow(
                symbolName: "chevron.left.forwardslash.chevron.right",
                symbolColor: .labelColor,
                title: "GitHub 项目",
                url: "https://github.com/BlackSquarre/VoiceInputAlpha"
            )
        )

        vStack.addArrangedSubview(linksStack)
        vStack.setCustomSpacing(20, after: linksStack)

        // ── 分割线 ────────────────────────────────────────────
        let sep2 = makeSeparator()
        vStack.addArrangedSubview(sep2)
        sep2.widthAnchor.constraint(equalTo: vStack.widthAnchor, constant: -40).isActive = true
        vStack.setCustomSpacing(12, after: sep2)

        // ── 版权 ──────────────────────────────────────────────
        let copyright = NSTextField(labelWithString: "© 2026 缪凌儒. 保留所有权利。")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .tertiaryLabelColor
        vStack.addArrangedSubview(copyright)

        self.window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Helpers

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// 图标 + 可点击链接文字的水平行
    private func makeLinkRow(symbolName: String, symbolColor: NSColor, title: String, url: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        // SF Symbol 图标
        let icon = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = symbolColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        // 链接按钮
        let btn = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.contentTintColor = .linkColor
        btn.font = .systemFont(ofSize: 13)
        btn.toolTip = url
        // 存 URL 到 identifier
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        // 鼠标悬停时显示手型光标
        btn.addCursorRect(btn.bounds, cursor: .pointingHand)
        // 下划线
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 13),
        ]
        btn.attributedTitle = NSAttributedString(string: title, attributes: attrs)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(btn)
        return row
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }
}
