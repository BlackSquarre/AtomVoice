import Cocoa

final class AboutWindowController: NSObject {
    private var window: NSWindow?
    private var thirdPartyWindow: NSWindow?

    private struct ThirdPartyNotice {
        let name: String
        let license: String
        let projectURL: String
        let licenseURL: String
    }

    private let thirdPartyNotices: [ThirdPartyNotice] = [
        ThirdPartyNotice(
            name: "sherpa-onnx",
            license: "Apache License 2.0",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx",
            licenseURL: "https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE"
        ),
        ThirdPartyNotice(
            name: "ONNX Runtime",
            license: "MIT License",
            projectURL: "https://github.com/microsoft/onnxruntime",
            licenseURL: "https://github.com/microsoft/onnxruntime/blob/main/LICENSE"
        ),
        ThirdPartyNotice(
            name: "k2-fsa Sherpa ONNX ASR models",
            license: "See model repository",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models",
            licenseURL: "https://github.com/k2-fsa/sherpa-onnx"
        ),
        ThirdPartyNotice(
            name: "k2-fsa Sherpa ONNX punctuation model",
            license: "See model repository",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/punctuation-models",
            licenseURL: "https://github.com/k2-fsa/sherpa-onnx"
        ),
        ThirdPartyNotice(
            name: "ReazonSpeech",
            license: "Apache License 2.0",
            projectURL: "https://github.com/reazon-research/ReazonSpeech",
            licenseURL: "https://github.com/reazon-research/ReazonSpeech/blob/master/LICENSE"
        ),
    ]

    func showWindow() {
        if let w = window {
            WindowPresenter.shared.bringToFrontInCurrentSpace(w)
            return
        }
        buildWindow()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 316),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = loc("about.title")
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        guard let cv = w.contentView else { return }

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.alignment = .centerX
        vStack.spacing = 0
        vStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(vStack)

        // 顶部留出 titlebar 区域（Leave space for titlebar at top）
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 36),
            vStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            vStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            vStack.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -20),
        ])

        // ── 图标（Icon）────────────────────────────────────────────────
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        vStack.addArrangedSubview(iconView)
        vStack.setCustomSpacing(12, after: iconView)

        // ── 应用名称（App Name）──────────────────────────────────────────
        let nameLabel = NSTextField(labelWithString: loc("about.appName"))
        nameLabel.font = .boldSystemFont(ofSize: 17)
        nameLabel.textColor = .labelColor
        vStack.addArrangedSubview(nameLabel)
        vStack.setCustomSpacing(2, after: nameLabel)

        // ── 英文副标题（English subtitle, shown in non-English locales）────────────────────────
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

        // ── 版本号（Version）────────────────────────────────────────────
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let verLabel = NSTextField(labelWithString: loc("about.version", version, build))
        verLabel.font = .systemFont(ofSize: 11.5)
        verLabel.textColor = .secondaryLabelColor
        vStack.addArrangedSubview(verLabel)
        vStack.setCustomSpacing(4, after: verLabel)

        // ── 开发构建标识（Development build badge, DEBUG_BUILD only）────────────────
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

        // ── 链接：Bilibili + GitHub 左右排列，仅图标，浅色（Links: Bilibili + GitHub side by side, icon-only, light tint）──────────────
        let linksRow = NSStackView()
        linksRow.orientation = .horizontal
        linksRow.spacing = 20
        linksRow.alignment = .centerY
        linksRow.addArrangedSubview(makeLinkIcon(
            svgName: "bilibili",
            fallbackSymbol: "play.circle",
            url: "https://space.bilibili.com/404899",
            accessibilityLabel: "Bilibili",
            toolTip: loc("tooltip.about.bilibili")
        ))
        linksRow.addArrangedSubview(makeLinkIcon(
            svgName: "github",
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            url: "https://github.com/BlackSquarre/AtomVoice",
            accessibilityLabel: "GitHub",
            toolTip: loc("tooltip.about.github")
        ))
        vStack.addArrangedSubview(linksRow)
        vStack.setCustomSpacing(20, after: linksRow)

        let thirdPartyButton = makeTextButton(
            title: loc("about.thirdParty.link"),
            action: #selector(showThirdPartyNotices(_:))
        )
        thirdPartyButton.font = .systemFont(ofSize: 10.5)
        thirdPartyButton.contentTintColor = .tertiaryLabelColor
        vStack.addArrangedSubview(thirdPartyButton)
        vStack.setCustomSpacing(8, after: thirdPartyButton)

        // ── 版权（Copyright）────────────────────────────────────────────
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
        WindowPresenter.shared.bringToFrontInCurrentSpace(w)
    }

    // MARK: - Icon-only link button

    private func makeLinkIcon(svgName: String, fallbackSymbol: String,
                               url: String, accessibilityLabel: String,
                               toolTip: String) -> NSView {
        let btn = NSButton(title: "", target: self, action: #selector(openLink(_:)))
        btn.isBordered = false
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        btn.setAccessibilityLabel(accessibilityLabel)
        btn.toolTip = toolTip
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
        imgView.contentTintColor = .secondaryLabelColor   // 浅色（Light tint）

        btn.addSubview(imgView)
        NSLayoutConstraint.activate([
            imgView.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            imgView.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 20),
            imgView.heightAnchor.constraint(equalToConstant: 20),
        ])
        return btn
    }

    private func makeTextButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.setButtonType(.momentaryChange)
        btn.alignment = .center
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    private func makeExternalLinkButton(title: String, url: String) -> NSButton {
        let btn = makeTextButton(title: title, action: #selector(openLink(_:)))
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        btn.font = .systemFont(ofSize: 12)
        btn.contentTintColor = .linkColor
        return btn
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showThirdPartyNotices(_ sender: NSButton) {
        if let w = thirdPartyWindow {
            WindowPresenter.shared.bringToFrontInCurrentSpace(w)
            return
        }

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = loc("about.thirdParty.title")
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        guard let cv = w.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: 46),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])

        let title = NSTextField(labelWithString: loc("about.thirdParty.title"))
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .labelColor
        root.addArrangedSubview(title)

        let intro = NSTextField(labelWithString: loc("about.thirdParty.intro"))
        intro.font = .systemFont(ofSize: 12.5)
        intro.textColor = .secondaryLabelColor
        intro.lineBreakMode = .byWordWrapping
        intro.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(list)
        scrollView.documentView = documentView
        root.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            list.topAnchor.constraint(equalTo: documentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        for notice in thirdPartyNotices {
            list.addArrangedSubview(makeNoticeView(notice))
        }

        self.thirdPartyWindow = w
        w.delegate = self
        w.center()
        WindowPresenter.shared.bringToFrontInCurrentSpace(w)
    }

    private func makeNoticeView(_ notice: ThirdPartyNotice) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: notice.name)
        name.font = .boldSystemFont(ofSize: 13.5)
        name.textColor = .labelColor
        stack.addArrangedSubview(name)

        let license = NSTextField(labelWithString: loc("about.thirdParty.license", notice.license))
        license.font = .systemFont(ofSize: 12)
        license.textColor = .secondaryLabelColor
        stack.addArrangedSubview(license)

        let links = NSStackView()
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 12
        links.addArrangedSubview(makeExternalLinkButton(title: loc("about.thirdParty.project"), url: notice.projectURL))
        links.addArrangedSubview(makeExternalLinkButton(title: loc("about.thirdParty.licenseLink"), url: notice.licenseURL))
        stack.addArrangedSubview(links)

        return stack
    }
}

// MARK: - NSWindowDelegate

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
    }
}
