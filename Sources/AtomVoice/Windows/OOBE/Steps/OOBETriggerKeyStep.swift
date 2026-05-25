import Cocoa

enum OOBETriggerKeyStepLayout {
    static let leftColumnWidth: CGFloat = 390
}

final class OOBETriggerKeyStep: OOBEStep {
    private unowned let state: OOBESelectionState
    private var keyboardDiagramView: KeyboardDiagramView?
    private var triggerSubtitleLabel: NSTextField?
    private var triggerSelectionLabel: NSTextField?
    private var inputModeDescLabel: NSTextField?
    private var headphoneControlCard: OOBEHeadphoneControlCardView?

    init(state: OOBESelectionState) {
        self.state = state
    }

    func makeView() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.trigger.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let subLocKey = state.silenceAutoStop ? "oobe.trigger.subtitle.tap" : "oobe.trigger.subtitle"
        let sub = NSTextField(labelWithString: loc(subLocKey))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        triggerSubtitleLabel = sub
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(20, after: sub)

        // 左侧：键盘示意图 + 当前选中键名 + 触发方式
        // (Left: keyboard diagram + current key label + input mode)
        let diagram = KeyboardDiagramView()
        diagram.translatesAutoresizingMaskIntoConstraints = false
        diagram.onSelect = { [weak self] code in self?.triggerKeySelected(code) }
        diagram.setSelected(state.triggerKeyCode)
        keyboardDiagramView = diagram

        let label = NSTextField(labelWithString: triggerKeyLabel(for: state.triggerKeyCode))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        triggerSelectionLabel = label

        // 触发方式分段控件：长按说话 / 单击说话
        // (Input mode segmented control: hold-to-talk / tap-to-talk)
        let modeHeading = NSTextField(labelWithString: loc("oobe.trigger.mode.title"))
        modeHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        modeHeading.textColor = .labelColor

        let modeSegment = NSSegmentedControl(labels: [loc("oobe.trigger.mode.hold"),
                                                       loc("oobe.trigger.mode.tap")],
                                              trackingMode: .selectOne,
                                              target: self,
                                              action: #selector(inputModeChanged(_:)))
        modeSegment.selectedSegment = state.silenceAutoStop ? 1 : 0
        modeSegment.segmentStyle = .rounded
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        modeSegment.setWidth(116, forSegment: 0)
        modeSegment.setWidth(104, forSegment: 1)

        let recommendedBadge = OOBERecommendedBadgeView(text: loc("oobe.engine.recommended"))
        recommendedBadge.translatesAutoresizingMaskIntoConstraints = false

        let modeControlRow = NSStackView(views: [modeSegment, recommendedBadge])
        modeControlRow.orientation = .horizontal
        modeControlRow.alignment = .centerY
        modeControlRow.spacing = 8

        let modeDesc = NSTextField(labelWithString: inputModeDescription())
        modeDesc.font = .systemFont(ofSize: 11.5)
        modeDesc.textColor = .tertiaryLabelColor
        modeDesc.alignment = .center
        modeDesc.lineBreakMode = .byWordWrapping
        modeDesc.maximumNumberOfLines = 0
        modeDesc.preferredMaxLayoutWidth = OOBETriggerKeyStepLayout.leftColumnWidth
        inputModeDescLabel = modeDesc

        let modeStack = NSStackView(views: [modeHeading, modeControlRow, modeDesc])
        modeStack.orientation = .vertical
        modeStack.alignment = .centerX
        modeStack.spacing = 8

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .centerX
        leftStack.spacing = 18
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(diagram)
        leftStack.addArrangedSubview(label)
        leftStack.setCustomSpacing(24, after: label)
        leftStack.addArrangedSubview(modeStack)

        let headphoneCard = OOBEHeadphoneControlCardView()
        headphoneCard.translatesAutoresizingMaskIntoConstraints = false
        headphoneCard.setEnabled(state.headphoneControl)
        headphoneCard.updateModeDescription(selectedSilenceAutoStop: state.silenceAutoStop)
        headphoneCard.onToggle = { [weak self] enabled in
            self?.state.headphoneControl = enabled
        }
        headphoneControlCard = headphoneCard

        let contentRow = NSStackView(views: [leftStack, headphoneCard])
        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.distribution = .fill
        contentRow.spacing = 18
        contentRow.translatesAutoresizingMaskIntoConstraints = false

        let topSpacer = NSView()
        let botSpacer = NSView()

        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(contentRow)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true
        contentRow.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headphoneCard.setContentHuggingPriority(.required, for: .horizontal)
        leftStack.widthAnchor.constraint(equalToConstant: OOBETriggerKeyStepLayout.leftColumnWidth).isActive = true
        headphoneCard.widthAnchor.constraint(equalToConstant: OOBEHeadphoneControlCardLayout.cardWidth).isActive = true
        headphoneCard.heightAnchor.constraint(equalToConstant: OOBEHeadphoneControlCardLayout.cardHeight).isActive = true

        return v
    }

    @objc private func inputModeChanged(_ sender: NSSegmentedControl) {
        state.silenceAutoStop = sender.selectedSegment == 1
        inputModeDescLabel?.stringValue = inputModeDescription()
        let subLocKey = state.silenceAutoStop ? "oobe.trigger.subtitle.tap" : "oobe.trigger.subtitle"
        triggerSubtitleLabel?.stringValue = loc(subLocKey)
        headphoneControlCard?.updateModeDescription(selectedSilenceAutoStop: state.silenceAutoStop)
    }

    private func inputModeDescription() -> String {
        state.silenceAutoStop
            ? loc("oobe.trigger.mode.tap.desc")
            : loc("oobe.trigger.mode.hold.desc")
    }

    private func triggerKeyLabel(for code: UInt16) -> String {
        let opt = TriggerKeyOption.option(for: code)
        return String(format: loc("oobe.trigger.selected"), loc(opt.locKey))
    }

    private func triggerKeySelected(_ code: UInt16) {
        state.triggerKeyCode = code
        keyboardDiagramView?.setSelected(code)
        triggerSelectionLabel?.stringValue = triggerKeyLabel(for: code)
    }

}
