import Cocoa

// MARK: - Dynamic Colors (macOS 26 adaptive)

private extension NSColor {
    /// 权限卡片背景：浅色模式接近白色，深色模式略亮于窗口背景（Permission card background: near-white in light mode, slightly brighter than window background in dark mode）
    static let permissionCard = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    }
    /// 数字徽标底色（Badge fill color）
    static let badgeFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.38, alpha: 1)
            : NSColor(white: 0.58, alpha: 1)
    }
}

// MARK: - PermissionsWindowController

final class PermissionsWindowController: NSObject {
    private let permissionService = PermissionService.shared
    private var window: NSWindow?
    private var rowViews: [PermissionRowView] = []
    private var refreshTimer: Timer?

    func showWindow() {
        if let w = window {
            refresh()
            WindowPresenter.shared.bringToFront(w)
            return
        }
        buildWindow()
        startRefreshTimer()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("permissions.window.title")
        w.isReleasedWhenClosed = false
        w.delegate = self

        guard let cv = w.contentView else { return }

        // 左侧面板：NSVisualEffectView 自动适配深浅色（Left panel: NSVisualEffectView auto-adapts to light/dark mode）
        let leftPanel = makeLeftPanel()
        // 垂直分割线（Vertical separator line）
        let vLine = NSBox()
        vLine.boxType = .separator
        vLine.translatesAutoresizingMaskIntoConstraints = false
        // 右侧面板（Right panel）
        let rightPanel = makeRightPanel()

        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(leftPanel)
        cv.addSubview(vLine)
        cv.addSubview(rightPanel)

        NSLayoutConstraint.activate([
            leftPanel.topAnchor.constraint(equalTo: cv.topAnchor),
            leftPanel.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            leftPanel.widthAnchor.constraint(equalToConstant: 268),

            vLine.topAnchor.constraint(equalTo: cv.topAnchor),
            vLine.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            vLine.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            vLine.widthAnchor.constraint(equalToConstant: 1),

            rightPanel.topAnchor.constraint(equalTo: cv.topAnchor),
            rightPanel.leadingAnchor.constraint(equalTo: vLine.trailingAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        self.window = w
        refresh()
        w.center()
        WindowPresenter.shared.bringToFront(w)
    }

    // MARK: - Left Guide Panel

    private func makeLeftPanel() -> NSView {
        // NSVisualEffectView 自动跟随系统外观，提供 sidebar 质感（NSVisualEffectView auto-follows system appearance, provides sidebar texture）
        let panel = NSVisualEffectView()
        panel.material = .sidebar
        panel.blendingMode = .behindWindow
        panel.state = .active

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 14
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 36),
            vStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            vStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
        ])

        // App 图标（App icon）
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        vStack.addArrangedSubview(iconView)
        vStack.setCustomSpacing(22, after: iconView)

        let heading = NSTextField(labelWithString: loc("permissions.guide.title"))
        heading.font = .systemFont(ofSize: 13.5, weight: .semibold)
        heading.textColor = .labelColor
        vStack.addArrangedSubview(heading)
        vStack.setCustomSpacing(16, after: heading)

        let steps = [
            loc("permissions.guide.step1"),
            loc("permissions.guide.step2"),
            loc("permissions.guide.step3"),
        ]
        for (i, text) in steps.enumerated() {
            let row = makeStepRow(number: i + 1, text: text)
            vStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
            if i < steps.count - 1 {
                vStack.setCustomSpacing(12, after: row)
            }
        }

        return panel
    }

    private func makeStepRow(number: Int, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .top

        // 圆形数字徽标（Circular number badge）
        let badge = CircleBadgeView(number: number)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(badge)

        let textLabel = NSTextField(labelWithString: text)
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(textLabel)

        return row
    }

    // MARK: - Right Permissions Panel

    private func makeRightPanel() -> NSView {
        let panel = NSView()

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            vStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            vStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            vStack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -20),
        ])

        let heading = NSTextField(labelWithString: loc("permissions.heading"))
        heading.font = .boldSystemFont(ofSize: 18)
        heading.textColor = .labelColor
        heading.lineBreakMode = .byWordWrapping
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vStack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        vStack.setCustomSpacing(22, after: heading)

        rowViews = []
        let permissions: [(String, String, Int)] = [
            (loc("permission.accessibility.title"), loc("permission.accessibility.desc"), 0),
            (loc("permission.microphone.title"),    loc("permission.microphone.desc"),    1),
            (loc("permission.speech.title"),         loc("permission.speech.desc"),        2),
        ]
        for (i, p) in permissions.enumerated() {
            let row = PermissionRowView(title: p.0, desc: p.1, tag: p.2,
                                        target: self, action: #selector(handleAction(_:)))
            vStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
            rowViews.append(row)
            vStack.setCustomSpacing(i < permissions.count - 1 ? 10 : 22, after: row)
        }

        // 分割线（Separator line）
        let sep = NSBox()
        sep.boxType = .separator
        vStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        vStack.setCustomSpacing(14, after: sep)

        // 故障排除（Troubleshooting）
        let troubleLabel = NSTextField(labelWithString: loc("permissions.troubleshoot"))
        troubleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        troubleLabel.textColor = .tertiaryLabelColor
        vStack.addArrangedSubview(troubleLabel)
        vStack.setCustomSpacing(8, after: troubleLabel)

        let resetBtn = NSButton(title: loc("permissions.reset"), target: self, action: #selector(resetPermissions))
        resetBtn.toolTip = loc("tooltip.permissions.reset")
        resetBtn.bezelStyle = .rounded
        vStack.addArrangedSubview(resetBtn)
        vStack.setCustomSpacing(22, after: resetBtn)

        // 关闭按钮（右对齐）（Close button, right-aligned）
        let closeRow = NSStackView()
        closeRow.orientation = .horizontal
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeRow.addArrangedSubview(spacer)
        let closeBtn = NSButton(title: loc("permissions.close"), target: self, action: #selector(closeWindow))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeRow.addArrangedSubview(closeBtn)
        vStack.addArrangedSubview(closeRow)
        closeRow.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true

        return panel
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard rowViews.count >= 3 else { return }
        rowViews[0].update(status: permissionService.status(for: .accessibility))
        rowViews[1].update(status: permissionService.status(for: .microphone))
        rowViews[2].update(status: permissionService.status(for: .speechRecognition))
    }

    // MARK: - Actions

    @objc private func handleAction(_ sender: NSButton) {
        guard let kind = PermissionKind(permissionCardTag: sender.tag) else { return }
        permissionService.requestOrOpenSettings(for: kind) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = loc("permissions.reset.confirm.title")
        alert.informativeText = loc("permissions.reset.confirm.message")
        alert.addButton(withTitle: loc("permissions.reset.confirm.ok"))
        alert.addButton(withTitle: loc("settings.cancel"))
        guard AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "--args", "-e",
            "tccutil reset Microphone com.blacksquarre.AtomVoice && " +
            "tccutil reset SpeechRecognition com.blacksquarre.AtomVoice && " +
            "printf '%s\\n' \(shellQuoted(loc("permissions.reset.terminalDone")))"]
        try? task.run()
    }

    @objc private func closeWindow() { window?.close() }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - NSWindowDelegate

extension PermissionsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}

// MARK: - Circle Badge View (数字圆形徽标)

private final class CircleBadgeView: NSView {
    private let number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .circular

        let label = NSTextField(labelWithString: "\(number)")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.badgeFill.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Permission Row View

final class PermissionRowView: NSView {
    private let titleLabel: NSTextField
    private let descLabel: NSTextField
    private let actionBtn: NSButton
    // 状态圆点：直接用 NSView + layer 绘制（Status dot: drawn with NSView + layer）
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentDotColor: NSColor = .systemGray

    init(title: String, desc: String, tag: Int, target: AnyObject, action: Selector) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.descLabel = NSTextField(labelWithString: desc)
        self.actionBtn = NSButton(title: "", target: target, action: action)
        super.init(frame: .zero)
        self.actionBtn.tag = tag
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    // 卡片背景跟随系统外观（Card background follows system appearance）
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.permissionCard.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        // 圆点颜色也需要刷新（已是 CGColor，需重设）（Dot color also needs refresh — already CGColor, needs reassignment）
        statusDot.layer?.backgroundColor = currentDotColor.cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 12          // macOS 26 更大圆角（macOS 26 larger corner radius）
        layer?.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        descLabel.font = .systemFont(ofSize: 11.5)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        actionBtn.bezelStyle = .rounded
        actionBtn.translatesAutoresizingMaskIntoConstraints = false

        // 状态圆点（12pt 实心圆）（Status dot: 12pt solid circle）
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 6
        statusDot.layer?.cornerCurve = .circular
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(descLabel)
        addSubview(actionBtn)
        addSubview(statusDot)
        addSubview(statusLabel)

        // 布局：（Layout:）
        //   Title                          （顶部左侧 / top-left）
        //   Description（全宽，自动折行 / full width, auto-wraps）
        //   [Button — 占满左侧]   [● 状态文字]  （底部行 / bottom row）
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // 状态文字固定在右边缘（Status text pinned to right edge）
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: actionBtn.centerYAnchor),

            // 圆点紧贴状态文字左侧（Dot positioned just left of status text）
            statusDot.widthAnchor.constraint(equalToConstant: 12),
            statusDot.heightAnchor.constraint(equalToConstant: 12),
            statusDot.centerYAnchor.constraint(equalTo: actionBtn.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),

            // 按钮从左边延伸到圆点左侧（Button extends from left to left side of dot）
            actionBtn.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            actionBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionBtn.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -16),
            actionBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
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
