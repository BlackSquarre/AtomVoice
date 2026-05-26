import Cocoa

// MARK: - OOBE Window Controller
// 首次启动引导窗口（First-launch onboarding window）
// 5 步线性流程：欢迎 → 权限 → 触发键 → 引擎选择 → 完成
// (5-step linear flow: Welcome → Permissions → Trigger Key → Engine → Done)

final class OOBEWindowController: NSObject {
    static let completionDefaultsKey = "hasCompletedOOBE"

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
    private var activeStepIndex: Int?
    private let totalSteps = 5

    // 选中状态（Selection state）
    private let state = OOBESelectionState()

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
        state.engine = ASREngineRegistry.shared.normalizedCode(for: AppSettings.recognitionEngine)
        state.triggerKeyCode = AppSettings.triggerKeyCode
        state.silenceAutoStop = AppSettings.silenceAutoStopEnabled
        state.headphoneControl = AppSettings.headphoneControlEnabled
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

    private lazy var steps: [OOBEStep] = [
        OOBEWelcomeStep(),
        OOBEPermissionsStep(permissionService: .shared),
        OOBETriggerKeyStep(state: state),
        OOBEEngineStep(state: state),
        OOBEDoneStep(state: state),
    ]

    // MARK: Step Navigation

    private func showStep(_ step: Int) {
        guard steps.indices.contains(step) else { return }
        if let activeStepIndex, steps.indices.contains(activeStepIndex) {
            steps[activeStepIndex].willDisappear()
        }
        activeStepIndex = step
        currentStep = step
        updateDots()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let activeStep = steps[step]
        let stepView = activeStep.makeView()
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
        activeStep.willAppear()
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
        if currentStep == 3 && state.engine == ASREngineRegistry.sherpaCode {
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
        AppSettings.hasCompletedOOBE = true
        AppSettings.recognitionEngine = state.engine
        AppSettings.triggerKeyCode = state.triggerKeyCode
        AppSettings.silenceAutoStopEnabled = state.silenceAutoStop
        AppSettings.headphoneControlEnabled = state.headphoneControl
        if state.headphoneControl {
            AppSettings.headphoneControlAlertShown = true
        }
        if state.engine == VolcengineASRSettings.engineCode {
            AppSettings.doubaoASRPrivacyAccepted = true
        }
        let chosenEngine = state.engine
        let chosenKey = state.triggerKeyCode
        window?.close()
        onFinish?(chosenEngine, chosenKey)
    }



}

// MARK: - NSWindowDelegate

extension OOBEWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let activeStepIndex, steps.indices.contains(activeStepIndex) {
            steps[activeStepIndex].willDisappear()
        }
        activeStepIndex = nil
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
    }
}
