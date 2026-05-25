import Cocoa

// MARK: - Keyboard Diagram (mac 笔记本底排示意图)
// 画一个简化的 mac 键盘最底两排，候选 4 个键以彩色高亮可点击；
// 其余键以装饰浅灰矩形呈现，便于用户对照真实键位。
// (Render simplified bottom two rows of a Mac keyboard. The 4 candidate
// keys are colored & clickable; the rest are decorative grey caps.)

enum OOBETriggerKeyStepLayout {
    static let leftColumnWidth: CGFloat = 390
}

final class KeyboardDiagramView: NSView {
    var onSelect: ((UInt16) -> Void)?
    private var keyCaps: [KeyCap] = []
    private var selectedCode: UInt16 = 61

    override var intrinsicContentSize: NSSize {
        NSSize(width: OOBETriggerKeyStepLayout.leftColumnWidth, height: 126)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        buildKeyboard()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for cap in keyCaps { cap.refreshAppearance() }
    }

    func setSelected(_ code: UInt16) {
        selectedCode = code
        for cap in keyCaps {
            cap.setHighlighted(cap.keyCode == code)
        }
    }

    private func buildKeyboard() {
        // 顶部两排装饰键（Decorative rows: 14 + 14 caps）
        let row1 = makeDecorativeRow(count: 14, capWidth: 22)
        let row2 = makeDecorativeRow(count: 13, capWidth: 23, leftIndent: 12)
        // 修饰键底排（Modifier row — left modifiers + space + right modifiers）
        let row3 = makeModifierRow()

        let stack = NSStackView(views: [row1, row2, row3])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    private func makeDecorativeRow(count: Int, capWidth: CGFloat, leftIndent: CGFloat = 0) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        if leftIndent > 0 {
            let pad = NSView()
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.widthAnchor.constraint(equalToConstant: leftIndent).isActive = true
            row.addArrangedSubview(pad)
        }
        for _ in 0..<count {
            let cap = KeyCap(label: "", keyCode: nil, width: capWidth)
            row.addArrangedSubview(cap)
        }
        return row
    }

    private func makeModifierRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        // 左侧候选键（Left: candidate keys — Fn / Control / Option）
        let fn = makeCap(loc("menu.triggerKey.fn.symbol"), keyCode: 63, width: 30)
        let leftCtrl = makeCap("⌃", keyCode: 59, width: 30)
        let leftOpt  = makeCap("⌥", keyCode: 58, width: 30)
        let leftCmd  = KeyCap(label: "⌘", keyCode: nil, width: 36)
        // Space 装饰（decorative space bar）
        let space    = KeyCap(label: "", keyCode: nil, width: 105)
        // 右侧候选键（Right: candidate keys — Command / Option / Control）
        let rightCmd = makeCap("⌘", keyCode: 54, width: 36)
        let rightOpt = makeCap("⌥", keyCode: 61, width: 30)
        let rightCtl = makeCap("⌃", keyCode: 62, width: 30)

        [fn, leftCtrl, leftOpt, leftCmd, space, rightCmd, rightOpt, rightCtl].forEach {
            row.addArrangedSubview($0)
        }
        return row
    }

    private func makeCap(_ label: String, keyCode: UInt16, width: CGFloat) -> KeyCap {
        let cap = KeyCap(label: label, keyCode: keyCode, width: width)
        cap.onTap = { [weak self] code in self?.onSelect?(code) }
        keyCaps.append(cap)
        cap.setHighlighted(keyCode == selectedCode)
        return cap
    }
}



// MARK: - Single Key Cap

final class KeyCap: NSView {
    let keyCode: UInt16?  // nil = 装饰键，不可点击（Decorative cap, not interactive）
    var onTap: ((UInt16) -> Void)?

    private let labelView: NSTextField
    private var highlighted = false

    init(label: String, keyCode: UInt16?, width: CGFloat) {
        self.keyCode = keyCode
        self.labelView = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5

        labelView.alignment = .center
        labelView.font = .systemFont(ofSize: 10, weight: .semibold)
        labelView.textColor = .secondaryLabelColor
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 28),
            labelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if keyCode != nil {
            let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
            addGestureRecognizer(click)
        }
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        if let code = keyCode { onTap?(code) }
    }

    func setHighlighted(_ value: Bool) {
        highlighted = value
        refreshAppearance()
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let isCandidate = keyCode != nil
            let baseBG: NSColor = isDark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 1.0, alpha: 1)
            let decoBG: NSColor = isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.88, alpha: 1)

            if highlighted {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                labelView.textColor = .white
            } else if isCandidate {
                layer?.backgroundColor = baseBG.cgColor
                layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
                labelView.textColor = .labelColor
            } else {
                layer?.backgroundColor = decoBG.cgColor
                layer?.borderColor = NSColor.clear.cgColor
                labelView.textColor = .tertiaryLabelColor
            }
        }
    }

    override func resetCursorRects() {
        if keyCode != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
