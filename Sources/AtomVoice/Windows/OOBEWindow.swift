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
    private var selectedHeadphoneControl: Bool = false
    private var engineCardViews: [EngineCardView] = []
    private var keyboardDiagramView: KeyboardDiagramView?
    private var triggerSubtitleLabel: NSTextField?
    private var triggerSelectionLabel: NSTextField?
    private var inputModeDescLabel: NSTextField?
    private var headphoneControlCard: OOBEHeadphoneControlCardView?

    // 权限页（Permissions page）
    private var permissionCards: [OOBEPermissionCardView] = []
    private var permissionRefreshTimer: Timer?
    // 监听窗口外观变化，用于刷新 dots 颜色
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: Public

    func showWindow() {
        showWindow(initialStep: nil)
    }

    #if DEBUG_BUILD
    func showWindowForSnapshot(step: Int) {
        showWindow(initialStep: step)
    }
    #endif

    private func showWindow(initialStep: Int?) {
        if let w = window {
            WindowPresenter.shared.bringToFront(w)
            if let initialStep {
                showStep(max(0, min(totalSteps - 1, initialStep)))
            }
            return
        }
        selectedEngine = ASREngineRegistry.shared.normalizedCode(for: UserDefaults.standard.string(forKey: "recognitionEngine"))
        let savedKey = UInt16(UserDefaults.standard.integer(forKey: "triggerKeyCode"))
        selectedTriggerKeyCode = (savedKey == 0) ? 61 : savedKey
        selectedSilenceAutoStop = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        selectedHeadphoneControl = AppSettings.headphoneControlEnabled
        buildWindow(initialStep: initialStep)
    }

    // MARK: Build

    private func buildWindow(initialStep: Int?) {
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
        showStep(max(0, min(totalSteps - 1, initialStep ?? 0)))
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
        AppSettings.recognitionEngine = selectedEngine
        UserDefaults.standard.set(Int(selectedTriggerKeyCode), forKey: "triggerKeyCode")
        UserDefaults.standard.set(selectedSilenceAutoStop, forKey: "silenceAutoStopEnabled")
        AppSettings.headphoneControlEnabled = selectedHeadphoneControl
        if selectedHeadphoneControl {
            AppSettings.headphoneControlAlertShown = true
        }
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
        triggerSubtitleLabel = sub
        v.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setCustomSpacing(20, after: sub)

        // 左侧：键盘示意图 + 当前选中键名 + 触发方式
        // (Left: keyboard diagram + current key label + input mode)
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
        headphoneCard.setEnabled(selectedHeadphoneControl)
        headphoneCard.updateModeDescription(selectedSilenceAutoStop: selectedSilenceAutoStop)
        headphoneCard.onToggle = { [weak self] enabled in
            self?.selectedHeadphoneControl = enabled
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
        selectedSilenceAutoStop = sender.selectedSegment == 1
        inputModeDescLabel?.stringValue = inputModeDescription()
        let subLocKey = selectedSilenceAutoStop ? "oobe.trigger.subtitle.tap" : "oobe.trigger.subtitle"
        triggerSubtitleLabel?.stringValue = loc(subLocKey)
        headphoneControlCard?.updateModeDescription(selectedSilenceAutoStop: selectedSilenceAutoStop)
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
