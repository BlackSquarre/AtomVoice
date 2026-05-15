import Cocoa

// MARK: - OOBE Window Controller
// 首次启动引导窗口（First-launch onboarding window）
// 5 步线性流程：欢迎 → 权限 → 触发键 → 引擎选择 → 完成
// (5-step linear flow: Welcome → Permissions → Trigger Key → Engine → Done)

final class OOBEWindowController: NSObject {
    static let completionDefaultsKey = "hasCompletedOOBE"

    private let permissionService = PermissionService.shared

    /// OOBE 完成回调（Called when user finishes OOBE）
    var onFinish: ((_ engineCode: String, _ triggerKeyCode: UInt16) -> Void)?

    /// 窗口关闭回调（无论是 Finish 还是点红色关闭按钮都会触发，用于释放控制器实例）
    /// (Window-close callback — fires for Finish or for the red close button, used to release this controller.)
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private var contentContainer: NSView!
    private var titleDots: [NSView] = []
    private var backButton: NSButton!
    private var nextButton: NSButton!

    private var currentStep: Int = 0
    private let totalSteps = 5

    // 选中状态（Selection state）
    private var selectedEngine: String = ASREngineRegistry.appleCode
    private var selectedTriggerKeyCode: UInt16 = 61
    private var selectedSilenceAutoStop: Bool = false
    private var engineCardViews: [EngineCardView] = []
    private var keyboardDiagramView: KeyboardDiagramView?
    private var triggerSubtitleLabel: NSTextField?
    private var triggerSelectionLabel: NSTextField?
    private var inputModeDescLabel: NSTextField?

    // 权限页（Permissions page）
    private var permissionCards: [OOBEPermissionCardView] = []
    private var permissionRefreshTimer: Timer?
    // 监听窗口外观变化，用于刷新 dots 颜色
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: Public

    func showWindow() {
        if let w = window {
            WindowPresenter.shared.bringToFront(w)
            return
        }
        selectedEngine = ASREngineRegistry.shared.normalizedCode(for: UserDefaults.standard.string(forKey: "recognitionEngine"))
        let savedKey = UInt16(UserDefaults.standard.integer(forKey: "triggerKeyCode"))
        selectedTriggerKeyCode = (savedKey == 0) ? 61 : savedKey
        selectedSilenceAutoStop = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        buildWindow()
    }

    // MARK: Build

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("oobe.window.title")
        w.isReleasedWhenClosed = false
        w.delegate = self

        guard let cv = w.contentView else { return }

        // 顶部步骤指示器（Top step indicator）
        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 8
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<totalSteps {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.cornerCurve = .circular
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dotRow.addArrangedSubview(dot)
            titleDots.append(dot)
        }

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: loc("oobe.back"), target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton = NSButton(title: loc("oobe.next"), target: self, action: #selector(nextTapped))
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerRow = NSStackView(views: [backButton, footerSpacer, nextButton])
        footerRow.orientation = .horizontal
        footerRow.spacing = 12
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(dotRow)
        cv.addSubview(contentContainer)
        cv.addSubview(footerRow)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: cv.topAnchor, constant: 28),
            contentContainer.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 28),
            contentContainer.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -28),
            contentContainer.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -14),

            footerRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            footerRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            footerRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),

            dotRow.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            dotRow.centerYAnchor.constraint(equalTo: footerRow.centerYAnchor),
        ])

        self.window = w
        // 监听外观切换，重新解析 dots 颜色
        appearanceObservation = w.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateDots() }
        }
        showStep(0)
        w.center()
        WindowPresenter.shared.bringToFront(w)
    }

    // MARK: Step Navigation

    private func showStep(_ step: Int) {
        currentStep = step
        updateDots()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        stopPermissionRefresh()

        let stepView: NSView
        switch step {
        case 0: stepView = makeWelcomeStep()
        case 1: stepView = makePermissionsStep()
        case 2: stepView = makeTriggerKeyStep()
        case 3: stepView = makeEngineStep()
        case 4: stepView = makeDoneStep()
        default: return
        }
        stepView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stepView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            stepView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        backButton.isHidden = (step == 0)
        nextButton.title = (step == totalSteps - 1) ? loc("oobe.done") : loc("oobe.next")
    }

    private func updateDots() {
        // 在当前外观下解析颜色，确保亮暗模均可见
        // (Resolve colours under the window’s effective appearance for both light & dark)
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let active   = NSColor.controlAccentColor.cgColor
            // tertiaryLabelColor 在亮色模式下透明度过低，改用 systemGray 确保双模均可见
            let inactive = NSColor.systemGray.withAlphaComponent(0.45).cgColor
            for (i, dot) in titleDots.enumerated() {
                dot.layer?.backgroundColor = (i == currentStep) ? active : inactive
            }
        }
    }

    @objc private func backTapped() {
        if currentStep > 0 { showStep(currentStep - 1) }
    }

    @objc private func nextTapped() {
        // 引擎选择步：选了 Sherpa 时插入模型选择器；其他引擎走原流程
        // (Engine step: when Sherpa is chosen, present model chooser first; other engines proceed normally)
        if currentStep == 3 && selectedEngine == ASREngineRegistry.sherpaCode {
            presentSherpaModelChooser()
            return
        }
        if currentStep == totalSteps - 1 {
            finish()
        } else {
            showStep(currentStep + 1)
        }
    }

    private var pendingSherpaChooser: SherpaModelChooserController?

    private func presentSherpaModelChooser() {
        let chooser = SherpaModelChooserController()
        pendingSherpaChooser = chooser
        chooser.onComplete = { [weak self] result in
            guard let self else { return }
            self.pendingSherpaChooser = nil
            // 取消则停留在引擎选择步；确认则推进到完成步
            // (Cancel keeps user on engine step; confirm advances to Done)
            if result != nil {
                self.showStep(self.currentStep + 1)
            }
        }
        chooser.runModal(over: window)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completionDefaultsKey)
        UserDefaults.standard.set(selectedEngine, forKey: "recognitionEngine")
        UserDefaults.standard.set(Int(selectedTriggerKeyCode), forKey: "triggerKeyCode")
        UserDefaults.standard.set(selectedSilenceAutoStop, forKey: "silenceAutoStopEnabled")
        if selectedEngine == VolcengineASRSettings.engineCode {
            UserDefaults.standard.set(true, forKey: "doubaoASRPrivacyAccepted")
        }
        let chosenEngine = selectedEngine
        let chosenKey = selectedTriggerKeyCode
        window?.close()
        onFinish?(chosenEngine, chosenKey)
    }

    // MARK: Step 0 — Welcome

    private func makeWelcomeStep() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 14

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: loc("oobe.welcome.title"))
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        // 主 Tagline：核心 slogan，比副标更显眼（Primary tagline — louder than subtitle）
        let tagline = NSTextField(labelWithString: loc("oobe.welcome.tagline"))
        tagline.font = .systemFont(ofSize: 16, weight: .medium)
        tagline.textColor = .labelColor
        tagline.alignment = .center
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 540

        let subtitle = NSTextField(labelWithString: loc("oobe.welcome.subtitle"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = 540

        let hint = NSTextField(labelWithString: loc("oobe.welcome.hint"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let topSpacer = NSView()
        let botSpacer = NSView()

        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(icon)
        v.setCustomSpacing(20, after: icon)
        v.addArrangedSubview(title)
        v.setCustomSpacing(6, after: title)
        v.addArrangedSubview(tagline)
        v.setCustomSpacing(64, after: tagline)
        v.addArrangedSubview(subtitle)
        v.setCustomSpacing(8, after: subtitle)
        v.addArrangedSubview(hint)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true

        return v
    }

    // MARK: Step 1 — Permissions

    private func makePermissionsStep() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.perm.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let sub = NSTextField(labelWithString: loc("oobe.perm.subtitle"))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(18, after: sub)

        // 三张横排竖版卡片（Three vertical cards arranged horizontally）
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false

        permissionCards = []
        let perms: [(String, String, String, NSColor, Int)] = [
            (loc("permission.accessibility.title"), loc("permission.accessibility.desc"),
             "accessibility", NSColor.systemBlue, 0),
            (loc("permission.microphone.title"),    loc("permission.microphone.desc"),
             "mic.fill", NSColor.systemPink, 1),
            (loc("permission.speech.title"),         loc("permission.speech.desc"),
             "waveform", NSColor.systemPurple, 2),
        ]
        for p in perms {
            let card = OOBEPermissionCardView(title: p.0, desc: p.1, iconName: p.2,
                                              iconColor: p.3, tag: p.4,
                                              target: self, action: #selector(permTapped(_:)))
            cards.addArrangedSubview(card)
            permissionCards.append(card)
        }
        v.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        refreshPermissions()
        startPermissionRefresh()
        return v
    }

    private func startPermissionRefresh() {
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }
    private func stopPermissionRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }
    private func refreshPermissions() {
        guard permissionCards.count >= 3 else { return }
        permissionCards[0].update(status: permissionService.status(for: .accessibility))
        permissionCards[1].update(status: permissionService.status(for: .microphone))
        permissionCards[2].update(status: permissionService.status(for: .speechRecognition))
    }

    @objc private func permTapped(_ sender: NSButton) {
        guard let kind = PermissionKind(permissionCardTag: sender.tag) else { return }
        permissionService.requestOrOpenSettings(for: kind) { [weak self] in
            self?.refreshPermissions()
        }
    }

    // MARK: Step 2 — Trigger Key

    private func makeTriggerKeyStep() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.trigger.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let subLocKey = selectedSilenceAutoStop ? "oobe.trigger.subtitle.tap" : "oobe.trigger.subtitle"
        let sub = NSTextField(labelWithString: loc(subLocKey))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(20, after: sub)

        // 居中放置一张键盘示意图 + 下方动态显示当前选中键名
        // (Centered keyboard diagram + dynamic label showing currently selected key)
        let diagram = KeyboardDiagramView()
        diagram.translatesAutoresizingMaskIntoConstraints = false
        diagram.onSelect = { [weak self] code in self?.triggerKeySelected(code) }
        diagram.setSelected(selectedTriggerKeyCode)
        keyboardDiagramView = diagram

        let label = NSTextField(labelWithString: triggerKeyLabel(for: selectedTriggerKeyCode))
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
        modeSegment.selectedSegment = selectedSilenceAutoStop ? 1 : 0
        modeSegment.segmentStyle = .rounded

        let modeDesc = NSTextField(labelWithString: inputModeDescription())
        modeDesc.font = .systemFont(ofSize: 11.5)
        modeDesc.textColor = .tertiaryLabelColor
        modeDesc.alignment = .center
        modeDesc.lineBreakMode = .byWordWrapping
        modeDesc.maximumNumberOfLines = 0
        modeDesc.preferredMaxLayoutWidth = 540
        inputModeDescLabel = modeDesc

        let modeStack = NSStackView(views: [modeHeading, modeSegment, modeDesc])
        modeStack.orientation = .vertical
        modeStack.alignment = .centerX
        modeStack.spacing = 8

        let centerStack = NSStackView()
        centerStack.orientation = .vertical
        centerStack.alignment = .centerX
        centerStack.spacing = 18
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.addArrangedSubview(diagram)
        centerStack.addArrangedSubview(label)
        centerStack.setCustomSpacing(28, after: label)
        centerStack.addArrangedSubview(modeStack)

        let topSpacer = NSView()
        let botSpacer = NSView()

        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(centerStack)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true
        centerStack.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        return v
    }

    @objc private func inputModeChanged(_ sender: NSSegmentedControl) {
        selectedSilenceAutoStop = sender.selectedSegment == 1
        inputModeDescLabel?.stringValue = inputModeDescription()
        let subLocKey = selectedSilenceAutoStop ? "oobe.trigger.subtitle.tap" : "oobe.trigger.subtitle"
        triggerSubtitleLabel?.stringValue = loc(subLocKey)
    }

    private func inputModeDescription() -> String {
        selectedSilenceAutoStop
            ? loc("oobe.trigger.mode.tap.desc")
            : loc("oobe.trigger.mode.hold.desc")
    }

    private func triggerKeyLabel(for code: UInt16) -> String {
        let opt = TriggerKeyOption.option(for: code)
        return String(format: loc("oobe.trigger.selected"), loc(opt.locKey))
    }

    private func triggerKeySelected(_ code: UInt16) {
        selectedTriggerKeyCode = code
        keyboardDiagramView?.setSelected(code)
        triggerSelectionLabel?.stringValue = triggerKeyLabel(for: code)
    }

    // MARK: Step 3 — Engine

    private func makeEngineStep() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0

        let heading = NSTextField(labelWithString: loc("oobe.engine.heading"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        v.addArrangedSubview(heading)
        v.setCustomSpacing(6, after: heading)

        let sub = NSTextField(labelWithString: loc("oobe.engine.subtitle"))
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 0
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(20, after: sub)

        // 三张卡片：从左到右 → 隐私由高到低
        // (Three cards: left-to-right = privacy high → low)
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false

        engineCardViews = []
        let entries: [EngineCardModel] = [
            EngineCardModel(
                code: ASREngineRegistry.sherpaCode,
                title: loc("oobe.engine.sherpa.title"),
                tagline: loc("oobe.engine.sherpa.tagline"),
                iconName: "lock.shield.fill",
                iconColor: NSColor.systemGreen,
                badge: nil,
                privacyLevel: .high,
                privacyText: loc("oobe.engine.privacy.high"),
                qualityStars: 3,
                qualityText: loc("oobe.engine.quality.fair"),
                costStyle: .free,
                costText: loc("oobe.engine.cost.free"),
                costFootnote: loc("oobe.engine.cost.localNote"),
                desc: loc("oobe.engine.sherpa.desc")
            ),
            EngineCardModel(
                code: ASREngineRegistry.appleCode,
                title: loc("oobe.engine.apple.title"),
                tagline: loc("oobe.engine.apple.tagline"),
                iconName: "apple.logo",
                iconColor: NSColor.labelColor,
                badge: nil,
                privacyLevel: .medium,
                privacyText: loc("oobe.engine.privacy.medium"),
                qualityStars: 4,
                qualityText: loc("oobe.engine.quality.good"),
                costStyle: .free,
                costText: loc("oobe.engine.cost.free"),
                costFootnote: nil,
                desc: loc("oobe.engine.apple.desc")
            ),
            EngineCardModel(
                code: VolcengineASRSettings.engineCode,
                title: loc("oobe.engine.doubao.title"),
                tagline: loc("oobe.engine.doubao.tagline"),
                iconName: "cloud.fill",
                iconColor: NSColor.systemBlue,
                badge: nil,
                privacyLevel: .low,
                privacyText: loc("oobe.engine.privacy.low"),
                qualityStars: 5,
                qualityText: loc("oobe.engine.quality.best"),
                costStyle: .paid,
                costText: loc("oobe.engine.cost.paid"),
                costFootnote: nil,
                desc: loc("oobe.engine.doubao.desc")
            ),
        ]
        for model in entries {
            let card = EngineCardView(model: model)
            card.onSelect = { [weak self] code in self?.engineSelected(code) }
            cards.addArrangedSubview(card)
            engineCardViews.append(card)
        }
        v.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        applyEngineSelection()
        return v
    }

    private func engineSelected(_ code: String) {
        selectedEngine = code
        applyEngineSelection()
    }

    private func applyEngineSelection() {
        for card in engineCardViews {
            card.setSelected(card.code == selectedEngine)
        }
    }

    // MARK: Step 4 — Done

    private func makeDoneStep() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 14

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 64, weight: .regular)
        check.contentTintColor = NSColor(red: 0.15, green: 0.78, blue: 0.33, alpha: 1)

        let title = NSTextField(labelWithString: loc("oobe.done.title"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .center

        // 按选中触发键动态生成引导文案（Build body using selected trigger key）
        let opt = TriggerKeyOption.option(for: selectedTriggerKeyCode)
        let bodyLocKey = selectedSilenceAutoStop ? "oobe.done.body.tap" : "oobe.done.body"
        let bodyText = String(format: loc(bodyLocKey), loc(opt.symbolKey))
        
        let font = NSFont.systemFont(ofSize: 13)
        let attrString = NSMutableAttributedString(string: bodyText, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        attrString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attrString.length))
        
        if let iconRange = bodyText.range(of: "(ICON)") {
            let nsRange = NSRange(iconRange, in: bodyText)
            var image: NSImage?
            if let url = Bundle.main.url(forResource: "atomvoice-status", withExtension: "svg", subdirectory: "Icons") {
                image = NSImage(contentsOf: url)
            } else {
                image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            }
            image?.isTemplate = true
            
            let attachment = NSTextAttachment()
            if let img = image {
                let size = NSSize(width: 15, height: 15)
                img.size = size
                
                let tintedImg = NSImage(size: size)
                tintedImg.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: size))
                NSColor.secondaryLabelColor.set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
                tintedImg.unlockFocus()
                
                attachment.image = tintedImg
                attachment.bounds = NSRect(x: 0, y: font.descender, width: 15, height: 15)
            }
            
            let attachString = NSMutableAttributedString(attachment: attachment)
            attachString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: attachString.length))
            attrString.replaceCharacters(in: nsRange, with: attachString)
        }
        
        let body = NSTextField(labelWithAttributedString: attrString)
        body.maximumNumberOfLines = 0
        body.preferredMaxLayoutWidth = 540

        let nextStepText: String
        switch selectedEngine {
        case VolcengineASRSettings.engineCode:
            nextStepText = loc("oobe.done.followup.doubao")
        case ASREngineRegistry.sherpaCode:
            nextStepText = loc("oobe.done.followup.sherpa")
        default:
            nextStepText = loc("oobe.done.followup.apple")
        }
        let followup = NSTextField(labelWithString: nextStepText)
        followup.font = .systemFont(ofSize: 12)
        followup.textColor = .tertiaryLabelColor
        followup.alignment = .center
        followup.lineBreakMode = .byWordWrapping
        followup.maximumNumberOfLines = 0
        followup.preferredMaxLayoutWidth = 540

        let topSpacer = NSView()
        let botSpacer = NSView()
        v.addArrangedSubview(topSpacer)
        v.addArrangedSubview(check)
        v.setCustomSpacing(16, after: check)
        v.addArrangedSubview(title)
        v.setCustomSpacing(8, after: title)
        v.addArrangedSubview(body)
        v.setCustomSpacing(20, after: body)
        v.addArrangedSubview(followup)
        v.addArrangedSubview(botSpacer)
        topSpacer.heightAnchor.constraint(equalTo: botSpacer.heightAnchor).isActive = true

        return v
    }
}

// MARK: - NSWindowDelegate

extension OOBEWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopPermissionRefresh()
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
    }
}

// MARK: - Engine Card

struct EngineCardModel {
    enum PrivacyLevel { case high, medium, low }
    /// 费用样式枚举，决定图标和颜色（Cost style: drives icon + color）
    enum CostStyle {
        case free            // 免费 → 绿色 ✓（包含本地离线"免费但需下载模型"）
        case paid            // 付费 → 橙色 信用卡
    }

    let code: String
    let title: String
    let tagline: String
    let iconName: String
    let iconColor: NSColor
    let badge: String?
    let privacyLevel: PrivacyLevel
    let privacyText: String
    let qualityStars: Int   // 1...5
    let qualityText: String
    let costStyle: CostStyle
    let costText: String
    /// 副注：例如本地离线"需下载模型"，灰色显示在主文之后
    /// (Footnote, e.g. "Model download" — shown in grey after main cost text)
    let costFootnote: String?
    let desc: String
}

final class EngineCardView: NSView {
    let code: String
    var onSelect: ((String) -> Void)?
    private var selected = false
    private let model: EngineCardModel

    init(model: EngineCardModel) {
        self.code = model.code
        self.model = model
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            layer?.backgroundColor = bg.cgColor
            layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.clear).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2

        // 顶部图标（Top icon）
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        iconView.contentTintColor = model.iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // 标题行（Title row with optional badge）
        let titleLabel = NSTextField(labelWithString: model.title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(titleLabel)
        if let badgeText = model.badge {
            titleRow.addArrangedSubview(makeBadge(text: badgeText))
        }

        // 副标题（Tagline — one-liner positioning）
        let tagline = NSTextField(labelWithString: model.tagline)
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 2

        // 属性区：隐私 + 费用各一行；星级单独一行（更大、视觉重点）
        // (Attributes: privacy + cost as inline rows; stars get a dedicated larger row)
        let privacyRow = makeInlineAttrRow(
            icon: makePrivacyDot(level: model.privacyLevel),
            text: model.privacyText,
            textColor: .labelColor
        )
        let costIconName: String
        let costColor: NSColor
        switch model.costStyle {
        case .free:
            costIconName = "checkmark.seal.fill"
            costColor = NSColor.systemGreen
        case .paid:
            costIconName = "creditcard.fill"
            costColor = NSColor.systemOrange
        }
        let costIcon = NSImageView()
        costIcon.image = NSImage(systemSymbolName: costIconName, accessibilityDescription: nil)
        costIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        costIcon.contentTintColor = costColor
        let costRow = makeInlineAttrRow(
            icon: costIcon,
            text: model.costText,
            textColor: costColor,
            footnote: model.costFootnote
        )

        // 星级单独一行（Stars on a dedicated row, larger）
        let starsView = makeStars(filled: model.qualityStars, pointSize: 16)
        let qualityLabel = NSTextField(labelWithString: model.qualityText)
        qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        qualityLabel.textColor = .secondaryLabelColor
        let qualityRow = NSStackView(views: [starsView, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualityRow.alignment = .centerY

        let attrStack = NSStackView()
        attrStack.orientation = .vertical
        attrStack.alignment = .leading
        attrStack.spacing = 10
        attrStack.addArrangedSubview(privacyRow)
        attrStack.addArrangedSubview(costRow)
        attrStack.setCustomSpacing(14, after: costRow)
        attrStack.addArrangedSubview(qualityRow)

        // 描述（Description）
        let descLabel = NSTextField(labelWithString: model.desc)
        descLabel.font = .systemFont(ofSize: 11.5)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(iconView)
        v.setCustomSpacing(12, after: iconView)
        v.addArrangedSubview(titleRow)
        v.setCustomSpacing(4, after: titleRow)
        v.addArrangedSubview(tagline)
        v.setCustomSpacing(18, after: tagline)
        v.addArrangedSubview(attrStack)
        v.setCustomSpacing(18, after: attrStack)
        // 分隔线 + 描述（Separator + description）
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(sep)
        v.setCustomSpacing(12, after: sep)
        v.addArrangedSubview(descLabel)

        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            v.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
        tagline.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        descLabel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        sep.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        addGestureRecognizer(click)
    }

    /// 内联属性行：图标 + 主文本 + 可选灰色副本
    /// (Inline attribute row: icon + main text + optional grey footnote)
    private func makeInlineAttrRow(icon: NSView, text: String, textColor: NSColor, footnote: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        // 统一图标容器尺寸，确保每行图标高度一致，使 .centerY 对齐稳定
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(iconContainer)
        row.addArrangedSubview(label)

        if let footnote = footnote, !footnote.isEmpty {
            let note = NSTextField(labelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
            row.addArrangedSubview(note)
        }
        return row
    }

    private func makePrivacyDot(level: EngineCardModel.PrivacyLevel) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.cornerCurve = .circular
        let color: NSColor
        switch level {
        case .high:   color = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)  // 🟢
        case .medium: color = NSColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1)  // 🟡
        case .low:    color = NSColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1)  // 🔴
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        // 内圆点 12×12，交给外层容器居中（makeInlineAttrRow 统一包 16×16 容器）
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return dot
    }

    private func makeStars(filled: Int, pointSize: CGFloat = 10) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        for i in 0..<5 {
            let star = NSImageView()
            let symbol = (i < filled) ? "star.fill" : "star"
            star.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            star.symbolConfiguration = .init(pointSize: pointSize, weight: .medium)
            star.contentTintColor = (i < filled)
                ? NSColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1)
                : .quaternaryLabelColor
            row.addArrangedSubview(star)
        }
        return row
    }

    private func makeBadge(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.cornerCurve = .continuous
        bg.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
        ])
        return bg
    }

    @objc private func cardClicked() {
        onSelect?(code)
    }

    func setSelected(_ value: Bool) {
        selected = value
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Keyboard Diagram (mac 笔记本底排示意图)
// 画一个简化的 mac 键盘最底两排，候选 4 个键以彩色高亮可点击；
// 其余键以装饰浅灰矩形呈现，便于用户对照真实键位。
// (Render simplified bottom two rows of a Mac keyboard. The 4 candidate
// keys are colored & clickable; the rest are decorative grey caps.)

final class KeyboardDiagramView: NSView {
    var onSelect: ((UInt16) -> Void)?
    private var keyCaps: [KeyCap] = []
    private var selectedCode: UInt16 = 61

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
        let row1 = makeDecorativeRow(count: 14, capWidth: 28)
        let row2 = makeDecorativeRow(count: 13, capWidth: 30, leftIndent: 14)
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
        let fn = makeCap(loc("menu.triggerKey.fn.symbol"), keyCode: 63, width: 36)
        let leftCtrl = makeCap("⌃", keyCode: 59, width: 36)
        let leftOpt  = makeCap("⌥", keyCode: 58, width: 36)
        let leftCmd  = KeyCap(label: "⌘", keyCode: nil, width: 44)
        // Space 装饰（decorative space bar）
        let space    = KeyCap(label: "", keyCode: nil, width: 168)
        // 右侧候选键（Right: candidate keys — Command / Option / Control）
        let rightCmd = makeCap("⌘", keyCode: 54, width: 44)
        let rightOpt = makeCap("⌥", keyCode: 61, width: 36)
        let rightCtl = makeCap("⌃", keyCode: 62, width: 36)

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

// MARK: - OOBE Permission Card (vertical layout matching engine cards)
// 权限页竖版卡片：与引擎卡风格一致，顶部彩色图标 + 标题 + 描述 + 状态 + 操作按钮
// (Vertical permission card matching engine-card style: icon → title → desc → status → action)

final class OOBEPermissionCardView: NSView {
    private let titleLabel: NSTextField
    private let descLabel: NSTextField
    private let actionBtn: NSButton
    private let iconView: NSImageView
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentDotColor: NSColor = .systemGray

    init(title: String, desc: String, iconName: String, iconColor: NSColor,
         tag: Int, target: AnyObject, action: Selector) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.descLabel = NSTextField(labelWithString: desc)
        self.actionBtn = NSButton(title: "", target: target, action: action)
        self.iconView = NSImageView()
        super.init(frame: .zero)
        self.actionBtn.tag = tag
        self.iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        self.iconView.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        self.iconView.contentTintColor = iconColor
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            layer?.backgroundColor = bg.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        statusDot.layer?.backgroundColor = currentDotColor.cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        descLabel.font = .systemFont(ofSize: 11.5)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.cornerCurve = .circular
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        actionBtn.bezelStyle = .rounded
        actionBtn.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(iconView)
        v.setCustomSpacing(12, after: iconView)
        v.addArrangedSubview(titleLabel)
        v.setCustomSpacing(6, after: titleLabel)
        v.addArrangedSubview(descLabel)

        // 底部固定区：分隔线 + 状态 + 按钮（Bottom block: separator + status + button）
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(v)
        addSubview(sep)
        addSubview(statusRow)
        addSubview(actionBtn)
        descLabel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sep.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -12),

            statusRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusRow.bottomAnchor.constraint(equalTo: actionBtn.topAnchor, constant: -10),

            actionBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
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
