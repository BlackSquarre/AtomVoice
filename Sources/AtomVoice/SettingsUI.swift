import Cocoa

enum SettingsUI {
    static func makeField(placeholder: String, delegate: NSTextFieldDelegate?) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = delegate
        return field
    }

    static func makeSecureField(placeholder: String, delegate: NSTextFieldDelegate?) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = delegate
        return field
    }

    static func makeCheckbox(title: String, tooltip: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: target, action: action)
        button.toolTip = tooltip
        return button
    }

    static func makeButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        else { button.bezelStyle = .rounded }
        return button
    }

    static func makeSecondaryLabel(_ text: String = "", fontSize: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func makeFormRow(labelText: String, control: NSView, labelWidth: CGFloat = 120, spacing: CGFloat = 8) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = spacing
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func makeBottomRow(statusLabel: NSTextField, buttons: [NSButton], spacing: CGFloat = 8) -> NSStackView {
        let views = [statusLabel] + buttons
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = spacing
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    static func pinArrangedSubviewsTrailing(in stack: NSStackView) {
        for subview in stack.arrangedSubviews {
            subview.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }
}
