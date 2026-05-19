import Cocoa

final class AboutWindowController: NSObject {
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var thirdPartyWindow: NSWindow?

    private struct ThirdPartyNotice {
        let name: String
        let license: String
        let projectURL: String
    }

    private let thirdPartyNotices: [ThirdPartyNotice] = [
        ThirdPartyNotice(
            name: "sherpa-onnx",
            license: "Apache License 2.0",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx"
        ),
        ThirdPartyNotice(
            name: "ONNX Runtime",
            license: "MIT License",
            projectURL: "https://github.com/microsoft/onnxruntime"
        ),
        ThirdPartyNotice(
            name: "k2-fsa Sherpa ONNX ASR models",
            license: "See model repository",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models"
        ),
        ThirdPartyNotice(
            name: "k2-fsa Sherpa ONNX punctuation model",
            license: "See model repository",
            projectURL: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/punctuation-models"
        ),
        ThirdPartyNotice(
            name: "ReazonSpeech",
            license: "Apache License 2.0",
            projectURL: "https://github.com/reazon-research/ReazonSpeech"
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("about.thirdParty.title")
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]

        guard let cv = w.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: 18),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -18),
        ])

        let intro = NSTextField(labelWithString: loc("about.thirdParty.intro"))
        intro.font = .systemFont(ofSize: 12.5)
        intro.textColor = .secondaryLabelColor
        intro.lineBreakMode = .byWordWrapping
        intro.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let listContainer = FlippedView()
        listContainer.wantsLayer = true
        listContainer.layer?.cornerRadius = 8
        listContainer.layer?.borderWidth = 1
        listContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        listContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listContainer

        listContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(list)

        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: listContainer.topAnchor),
            list.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor)
        ])

        for (index, notice) in thirdPartyNotices.enumerated() {
            if index > 0 {
                let separator = NSView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.wantsLayer = true
                separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
                list.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                    separator.leadingAnchor.constraint(equalTo: list.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: list.trailingAnchor)
                ])
            }
            list.addArrangedSubview(makeNoticeRowView(notice))
        }

        self.thirdPartyWindow = w
        w.delegate = self
        w.center()
        WindowPresenter.shared.bringToFrontInCurrentSpace(w)
    }

    private func makeNoticeRowView(_ notice: ThirdPartyNotice) -> NSView {
        let paddingContainer = NSView()
        paddingContainer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        paddingContainer.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: paddingContainer.topAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: paddingContainer.leadingAnchor, constant: 14),
            container.trailingAnchor.constraint(equalTo: paddingContainer.trailingAnchor, constant: -14),
            container.bottomAnchor.constraint(equalTo: paddingContainer.bottomAnchor, constant: -10)
        ])

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: notice.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(nameLabel)

        let licenseLabel = NSTextField(labelWithString: loc("about.thirdParty.license", notice.license))
        licenseLabel.font = .systemFont(ofSize: 11.5)
        licenseLabel.textColor = .secondaryLabelColor
        licenseLabel.lineBreakMode = .byTruncatingTail
        licenseLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(licenseLabel)

        container.addArrangedSubview(textStack)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(spacer)

        let linkIconButton = LinkIconButton(imageName: "arrow.up.forward.app", target: self, action: #selector(openLink(_:)), url: notice.projectURL)
        container.addArrangedSubview(linkIconButton)

        return paddingContainer
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class LinkIconButton: NSButton {
    init(imageName: String, target: AnyObject?, action: Selector?, url: String) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.identifier = NSUserInterfaceItemIdentifier(url)
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false

        if let symbolImage = NSImage(systemSymbolName: imageName, accessibilityDescription: nil) {
            self.image = symbolImage.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular))
        } else {
            self.title = "↗"
        }
        contentTintColor = .secondaryLabelColor

        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - NSWindowDelegate

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        // 主窗口关闭时才通知路由清空槽位；ThirdParty 子窗口关闭忽略
        // (Notify router only when the main window closes; ignore the ThirdParty subwindow)
        if (notification.object as? NSWindow) === window {
            onClose?()
        }
    }
}
