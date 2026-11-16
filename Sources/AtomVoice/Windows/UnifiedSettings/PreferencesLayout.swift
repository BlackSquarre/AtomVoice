import Cocoa

/// 设置页共享原生栈与分组布局；标签按可用空间换行，不固定列宽。
enum PreferencesLayout {
    static func column(_ views: [NSView], spacing: CGFloat = 16) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        return stack
    }

    static func group(title: String? = nil, rows: [NSView]) -> NSView {
        var children: [NSView] = []
        if let title, !title.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            SettingsUI.allowHorizontalWrapping(label)
            children.append(label)
        }

        var contents: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                contents.append(separator)
            }
            contents.append(row)
        }
        let stack = column(contents, spacing: 0)
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderType = .lineBorder
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 8
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = NSView()
        if let content = box.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        children.append(box)
        return column(children, spacing: 8)
    }

    static func row(title: String, detail: String? = nil, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        SettingsUI.allowHorizontalWrapping(label)
        var labels: [NSView] = [label]
        if let detail, !detail.isEmpty {
            let description = SettingsUI.makeSecondaryLabel(detail)
            SettingsUI.allowHorizontalWrapping(description)
            labels.append(description)
        }
        let copy = column(labels, spacing: 4)
        copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        control.setAccessibilityLabel(title)
        if let actions = control as? NSStackView, actions.orientation == .horizontal {
            // 复合控件必须按内容收紧，否则外层右对齐后，内部按钮仍停在左侧。
            actions.distribution = .fill
            actions.setHuggingPriority(.required, for: .horizontal)
            for item in actions.arrangedSubviews {
                item.setContentHuggingPriority(.required, for: .horizontal)
                item.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            if let first = actions.arrangedSubviews.first, let last = actions.arrangedSubviews.last {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
                    last.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
                ])
            }
        }
        let stack = NSStackView(views: [copy, control])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 默认 gravityAreas 在旧 AppKit 中会把两个控件挤在左侧；明确将余量交给文案列。
        NSLayoutConstraint.activate([
            copy.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            control.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
        ])
        let maximumControlWidth = control.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.65)
        maximumControlWidth.priority = .defaultHigh
        maximumControlWidth.isActive = true
        return stack
    }

    /// 分组内的次级操作保持自然宽度，并与设置行共用右侧边距。
    static func trailingActions(_ views: [NSView]) -> NSView {
        let actions = NSStackView(views: views)
        actions.orientation = .horizontal
        actions.distribution = .fill
        actions.alignment = .centerY
        actions.spacing = 8
        actions.setHuggingPriority(.required, for: .horizontal)
        for view in views {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        actions.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 14),
            actions.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
        ])
        return host
    }
}

/// 尺寸计算不读取屏幕或设置，供离线测试验证顶边锚定和多屏边界。
enum PreferencesWindowGeometry {
    static func targetFrame(
        currentFrame: NSRect,
        visibleFrame: NSRect,
        contentSize: NSSize,
        frameInsets: NSSize
    ) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return currentFrame }
        let width = min(visibleFrame.width, max(1, contentSize.width + max(0, frameInsets.width)))
        let height = min(visibleFrame.height, max(1, contentSize.height + max(0, frameInsets.height)))
        let x = min(max(currentFrame.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let top = min(max(currentFrame.maxY, visibleFrame.minY + height), visibleFrame.maxY)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

/// 设置窗口按内容伸缩，保留当前顶边；长内容由调用方的滚动容器承载。
final class AdaptivePreferencesWindow: NSWindow {
    private var preferredContentWidth: CGFloat = 760

    convenience init(title: String, preferredWidth: CGFloat = 760) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        preferredContentWidth = preferredWidth
        self.title = title
        isReleasedWhenClosed = false
        standardWindowButton(.miniaturizeButton)?.isEnabled = false
        standardWindowButton(.zoomButton)?.isEnabled = false
    }

    func resize(contentHeight: CGFloat, width: CGFloat? = nil, animated: Bool = true) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        let preferredWidth = width ?? preferredContentWidth
        guard preferredWidth.isFinite, preferredWidth > 0 else { return }
        let currentContent = contentRect(forFrameRect: frame).size
        let insets = NSSize(
            width: max(0, frame.width - currentContent.width),
            height: max(0, frame.height - currentContent.height)
        )
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let next = PreferencesWindowGeometry.targetFrame(
            currentFrame: frame,
            visibleFrame: visible,
            contentSize: NSSize(width: preferredWidth, height: contentHeight),
            frameInsets: insets
        )
        guard abs(next.width - frame.width) > 0.5 || abs(next.height - frame.height) > 0.5
            || abs(next.minX - frame.minX) > 0.5 || abs(next.minY - frame.minY) > 0.5 else { return }
        let shouldAnimate = animated && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(next, display: true, animate: shouldAnimate)
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.25 }
}
