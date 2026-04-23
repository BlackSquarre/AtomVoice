import Cocoa

final class AboutWindowController: NSObject {
    private var window: NSWindow?

    func showWindow() {
        if let w = window {
            AppDelegate.bringToFront(w)
            return
        }
        buildWindow()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = loc("about.title")
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true

        guard let cv = w.contentView else { return }

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.alignment = .centerX
        vStack.spacing = 0
        vStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(vStack)

        // 顶部留出 titlebar 区域
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 36),
            vStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            vStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            vStack.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -20),
        ])

        // ── 图标 ───────────────────────────────────────────────
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        vStack.addArrangedSubview(iconView)
        vStack.setCustomSpacing(12, after: iconView)

        // ── 应用名称 ────────────────────────────────────────────
        let nameLabel = NSTextField(labelWithString: loc("about.appName"))
        nameLabel.font = .boldSystemFont(ofSize: 17)
        nameLabel.textColor = .labelColor
        vStack.addArrangedSubview(nameLabel)
        vStack.setCustomSpacing(2, after: nameLabel)

        // ── 英文副标题（非英语环境显示）────────────────────────
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        if langCode != "en" {
            let enLabel = NSTextField(labelWithString: "AtomVoice")
            enLabel.font = .systemFont(ofSize: 11)
            enLabel.textColor = .tertiaryLabelColor
            vStack.addArrangedSubview(enLabel)
            vStack.setCustomSpacing(4, after: enLabel)
        } else {
            vStack.setCustomSpacing(4, after: nameLabel)
        }

        // ── 版本号 ──────────────────────────────────────────────
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let verLabel = NSTextField(labelWithString: loc("about.version", version, build))
        verLabel.font = .systemFont(ofSize: 11.5)
        verLabel.textColor = .secondaryLabelColor
        vStack.addArrangedSubview(verLabel)
        vStack.setCustomSpacing(4, after: verLabel)

        // ── 开发构建标识（仅 DEBUG_BUILD 时显示）────────────────
        #if DEBUG_BUILD
        let devBadge = NSTextField(labelWithString: "⚙ Development Build")
        devBadge.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        devBadge.textColor = .systemOrange
        devBadge.alignment = .center
        vStack.addArrangedSubview(devBadge)
        vStack.setCustomSpacing(16, after: devBadge)
        #else
        vStack.setCustomSpacing(20, after: verLabel)
        #endif

        // ── 链接：Bilibili + GitHub 左右排列，仅图标，浅色 ───────
        let linksRow = NSStackView()
        linksRow.orientation = .horizontal
        linksRow.spacing = 20
        linksRow.alignment = .centerY
        linksRow.addArrangedSubview(makeLinkIcon(
            svgName: "bilibili",
            fallbackSymbol: "play.circle",
            url: "https://space.bilibili.com/404899",
            accessibilityLabel: "Bilibili"
        ))
        linksRow.addArrangedSubview(makeLinkIcon(
            svgName: "github",
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            url: "https://github.com/BlackSquarre/AtomVoice",
            accessibilityLabel: "GitHub"
        ))
        vStack.addArrangedSubview(linksRow)
        vStack.setCustomSpacing(20, after: linksRow)

        // ── 版权 ────────────────────────────────────────────────
        let copyright = NSTextField(labelWithString: loc("about.copyright"))
        copyright.font = .systemFont(ofSize: 10.5)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .center
        copyright.lineBreakMode = .byWordWrapping
        copyright.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vStack.addArrangedSubview(copyright)
        copyright.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true

        self.window = w
        w.delegate = self
        w.center()
        AppDelegate.bringToFront(w)
    }

    // MARK: - Icon-only link button

    private func makeLinkIcon(svgName: String, fallbackSymbol: String,
                               url: String, accessibilityLabel: String) -> NSView {
        let btn = NSButton(title: "", target: self, action: #selector(openLink(_:)))
        btn.isBordered = false
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        btn.setAccessibilityLabel(accessibilityLabel)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let imgView = NSImageView()
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.imageScaling = .scaleProportionallyDown

        if let svgURL = Bundle.main.url(forResource: svgName, withExtension: "svg",
                                         subdirectory: "Icons"),
           let img = NSImage(contentsOf: svgURL) {
            img.size = NSSize(width: 20, height: 20)
            img.isTemplate = true
            imgView.image = img
        } else {
            imgView.image = NSImage(systemSymbolName: fallbackSymbol,
                                    accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        }
        imgView.contentTintColor = .secondaryLabelColor   // 浅色

        btn.addSubview(imgView)
        NSLayoutConstraint.activate([
            imgView.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            imgView.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 20),
            imgView.heightAnchor.constraint(equalToConstant: 20),
        ])
        return btn
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - NSWindowDelegate

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            AppDelegate.resetActivationIfNeeded(closing: w)
        }
    }
}
