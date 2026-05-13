import Cocoa
import Speech
import ServiceManagement

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let onLanguageChanged: () -> Void
    private let llmRefiner: LLMRefiner
    private let asrEngineRegistry: ASREngineRegistry
    private let textOutputSinkRegistry: TextOutputSinkRegistry?
    private let permissionService = PermissionService.shared
    private var settingsWindow: SettingsWindowController?
    private var doubaoSettingsWindow: DoubaoSettingsWindowController?
    private var asrSettingsWindow: ASRSettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var permissionsWindow: PermissionsWindowController?
    var onTriggerKeyChanged: ((UInt16) -> Void)?
    var onSherpaDownloadRequested: (() -> Void)?

    init(onLanguageChanged: @escaping () -> Void,
         llmRefiner: LLMRefiner,
         asrEngineRegistry: ASREngineRegistry = .shared,
         textOutputSinkRegistry: TextOutputSinkRegistry? = nil) {
        self.onLanguageChanged = onLanguageChanged
        self.llmRefiner = llmRefiner
        self.asrEngineRegistry = asrEngineRegistry
        self.textOutputSinkRegistry = textOutputSinkRegistry
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.statusBarIcon(accessibilityDescription: loc("app.title"))
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 顶部提示：按住/单击 [触发键] 开始语音输入（Top tip: hold/tap [trigger key] to start voice input）
        let triggerOption = TriggerKeyOption.option(for: AppSettings.triggerKeyCode)
        let isTapMode = AppSettings.silenceAutoStopEnabled
        let instructionFmt = loc(isTapMode ? "menu.tapKey" : "menu.holdKey")
        menu.addItem(makeSectionLabel(String(format: instructionFmt, loc(triggerOption.symbolKey))))
        menu.addItem(makeSectionLabel(loc("menu.startVoiceInput")))

        menu.addItem(.separator())

        // 识别语言（Recognition language）
        let langItem = makeMenuItem(title: loc("menu.language"), imageName: "globe")
        let langMenu = NSMenu()
        let currentLang = AppSettings.selectedLanguage
        for lang in AppSettings.appLanguageOptions {
            langMenu.addItem(
                makeMenuItem(
                    title: lang.displayName,
                    action: #selector(selectLanguage(_:)),
                    state: lang.code == currentLang ? .on : .off,
                    representedObject: lang.code
                )
            )
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // 识别引擎（Recognition engine）
        let engineItem = makeMenuItem(title: loc("menu.recognitionEngine"), imageName: "cpu")
        let engineMenu = NSMenu()
        let currentEngine = AppSettings.normalizedRecognitionEngine
        for descriptor in asrEngineRegistry.descriptors {
            engineMenu.addItem(
                makeMenuItem(
                    title: loc(descriptor.displayNameKey),
                    action: #selector(selectRecognitionEngine(_:)),
                    imageName: descriptor.iconName,
                    state: descriptor.code == currentEngine ? .on : .off,
                    representedObject: descriptor.code
                )
            )
        }
        engineMenu.addItem(.separator())

        // 识别引擎设置（Recognition engine settings）
        engineMenu.addItem(makeMenuItem(title: loc("menu.asrSettings"), action: #selector(openASRSettings(_:)), imageName: "gear"))

        engineMenu.addItem(
            makeMenuItem(
                title: loc("menu.engine.howto"),
                action: #selector(openEngineHowto(_:)),
                imageName: "questionmark.circle"
            )
        )

        engineMenu.addItem(.separator())

        // LLM 优化放在识别引擎菜单末尾，避免主菜单过长（Keep LLM refinement at the end of Recognition Engine to shorten the main menu）
        let llmItem = makeMenuItem(title: loc("menu.llm"), imageName: "wand.and.stars")
        llmItem.toolTip = loc("tooltip.menu.llm")
        let llmMenu = NSMenu()
        let llmEnabled = AppSettings.llmEnabled
        let toggleItem = makeMenuItem(
            title: llmEnabled ? loc("menu.llm.enabled") : loc("menu.llm.disabled"),
            action: #selector(toggleLLM(_:)),
            state: llmEnabled ? .on : .off
        )
        llmMenu.addItem(toggleItem)
        llmMenu.addItem(.separator())
        llmMenu.addItem(makeMenuItem(title: loc("menu.settings"), action: #selector(openSettings(_:)), imageName: "gear"))
        llmMenu.addItem(makeMenuItem(title: loc("menu.llm.howto"), action: #selector(openLLMHowto(_:)), imageName: "questionmark.circle"))
        llmItem.submenu = llmMenu
        engineMenu.addItem(llmItem)

        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // 自动标点（Auto punctuation）
        let punctEnabled = AppSettings.autoPunctuationEnabled
        menu.addItem(
            makeMenuItem(
                title: loc("menu.punctuation"),
                action: #selector(togglePunctuation(_:)),
                imageName: "text.badge.plus",
                state: punctEnabled ? .on : .off,
                toolTip: loc("tooltip.menu.punctuation")
            )
        )

        // 文本输出方式（Text output destination）
        if let outputRegistry = textOutputSinkRegistry, outputRegistry.descriptors.count > 1 {
            let outputItem = makeMenuItem(title: loc("menu.textOutput"), imageName: "square.and.arrow.up")
            let outputMenu = NSMenu()
            let currentOutput = outputRegistry.currentCode()
            for descriptor in outputRegistry.descriptors {
                outputMenu.addItem(
                    makeMenuItem(
                        title: loc(descriptor.displayNameKey),
                        action: #selector(selectTextOutputSink(_:)),
                        imageName: descriptor.iconName,
                        state: descriptor.code == currentOutput ? .on : .off,
                        representedObject: descriptor.code
                    )
                )
            }
            outputItem.submenu = outputMenu
            menu.addItem(outputItem)
        }

        menu.addItem(.separator())

        // 输入方式: 单击说话 or 长按说话（Input mode: tap to speak or hold to speak）
        let inputModeItem = makeMenuItem(title: loc("menu.inputMode"), imageName: "waveform")
        inputModeItem.toolTip = loc("tooltip.menu.inputMode")
        let inputModeMenu = NSMenu()
        inputModeMenu.addItem(makeMenuItem(title: loc("menu.inputMode.tap"), action: #selector(selectInputModeTap(_:)), state: isTapMode ? .on : .off))
        inputModeMenu.addItem(makeMenuItem(title: loc("menu.inputMode.hold"), action: #selector(selectInputModeHold(_:)), state: !isTapMode ? .on : .off))
        inputModeMenu.addItem(.separator())
        inputModeMenu.addItem(
            makeMenuItem(
                title: loc("menu.inputMode.liveInsertion"),
                action: #selector(toggleAppleLiveInsertion(_:)),
                state: AppSettings.appleLiveInsertionEnabled ? .on : .off,
                isEnabled: asrEngineRegistry.isApple(currentEngine),
                toolTip: loc("menu.inputMode.liveInsertion.tooltip")
            )
        )
        if isTapMode {
            inputModeMenu.addItem(.separator())
            inputModeMenu.addItem(makeSectionLabel(loc("menu.silence.duration")))
            let manualStop = AppSettings.tapModeManualStop
            let currentDuration = AppSettings.silenceDuration
            // "手动停止"：选中后不自动停录，必须再点一次触发键（Manual stop: disables auto-stop, requires a second trigger tap）
            inputModeMenu.addItem(
                makeMenuItem(
                    title: loc("menu.silence.manualStop"),
                    action: #selector(selectManualStop(_:)),
                    state: manualStop ? .on : .off,
                    indentationLevel: 1
                )
            )
            for (title, value) in [("0.5s", 0.5), ("1s", 1.0), ("1.5s", 1.5), ("2s", 2.0), ("3s", 3.0), ("5s", 5.0)] {
                let isSelected = !manualStop && abs(currentDuration - value) < 0.01
                inputModeMenu.addItem(
                    makeMenuItem(
                        title: title,
                        action: #selector(selectSilenceDuration(_:)),
                        state: isSelected ? .on : .off,
                        representedObject: value,
                        indentationLevel: 1
                    )
                )
            }
            inputModeMenu.addItem(.separator())
            inputModeMenu.addItem(makeSectionLabel(loc("menu.steadyNoise.sensitivity"), toolTip: loc("tooltip.menu.steadyNoise")))
            let currentSensitivity = AppSettings.steadyNoiseSensitivity
            for (title, value, tooltip) in [
                (loc("menu.steadyNoise.low"), 0, loc("tooltip.steadyNoise.low")),
                (loc("menu.steadyNoise.medium"), 1, loc("tooltip.steadyNoise.medium")),
                (loc("menu.steadyNoise.high"), 2, loc("tooltip.steadyNoise.high"))
            ] {
                inputModeMenu.addItem(
                    makeMenuItem(
                        title: title,
                        action: #selector(selectSteadyNoiseSensitivity(_:)),
                        state: currentSensitivity == value ? .on : .off,
                        representedObject: value,
                        indentationLevel: 1,
                        toolTip: tooltip
                    )
                )
            }
        }
        inputModeItem.submenu = inputModeMenu
        menu.addItem(inputModeItem)

        // 触发按键（Trigger key）
        let triggerItem = makeMenuItem(title: loc("menu.triggerKey"), imageName: "command")
        triggerItem.toolTip = loc("tooltip.menu.triggerKey")
        let triggerMenu = NSMenu()
        for option in TriggerKeyOption.all {
            let item = makeMenuItem(
                title: loc(option.locKey),
                action: #selector(selectTriggerKey(_:)),
                state: option.keyCode == triggerOption.keyCode ? .on : .off,
                representedObject: NSNumber(value: Int(option.keyCode))
            )
            // 将菜单标题中的 "Globe" 文字替换为 SF Symbol globe 图片
            // (Replace "Globe" text in menu title with SF Symbol globe image)
            if option.keyCode == 63 {
                let title = loc(option.locKey)
                if let range = title.range(of: "Globe") {
                    let attr = NSMutableAttributedString(string: String(title[..<range.lowerBound]), attributes: [
                        .font: NSFont.menuFont(ofSize: 0)
                    ])
                    if let globeImage = NSImage(systemSymbolName: "globe", accessibilityDescription: "Globe") {
                        let symbolConfig = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
                        if let configured = globeImage.withSymbolConfiguration(symbolConfig) {
                            let attachment = NSTextAttachment()
                            attachment.image = configured
                            let imageString = NSAttributedString(attachment: attachment)
                            attr.append(imageString)
                        }
                    }
                    attr.append(NSAttributedString(string: String(title[range.upperBound...]), attributes: [
                        .font: NSFont.menuFont(ofSize: 0)
                    ]))
                    item.attributedTitle = attr
                }
            }
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        // 音频输入设备（Audio input device）
        let audioInputItem = makeMenuItem(title: loc("menu.audioInput"), imageName: "mic.badge.plus")
        audioInputItem.toolTip = loc("tooltip.menu.audioInput")
        let audioInputMenu = NSMenu()
        let savedUID = AppSettings.audioInputDeviceUID
        audioInputMenu.addItem(
            makeMenuItem(
                title: loc("menu.audioInput.default"),
                action: #selector(selectAudioInput(_:)),
                state: savedUID.isEmpty ? .on : .off,
                representedObject: ""
            )
        )
        audioInputMenu.addItem(.separator())
        for device in AudioEngineController.availableInputDevices() {
            audioInputMenu.addItem(
                makeMenuItem(
                    title: device.name,
                    action: #selector(selectAudioInput(_:)),
                    state: device.uid == savedUID ? .on : .off,
                    representedObject: device.uid
                )
            )
        }
        audioInputItem.submenu = audioInputMenu
        menu.addItem(audioInputItem)

        menu.addItem(.separator())

        // 其他设置（子菜单：动画效果、开机启动、权限与帮助、检查更新、关于）（Other settings (submenu: animation, launch at login, permissions & help, check for updates, about)）
        let otherItem = makeMenuItem(title: loc("menu.otherSettings"), imageName: "ellipsis.circle")
        otherItem.submenu = buildOtherSettingsMenu()
        menu.addItem(otherItem)

        menu.addItem(.separator())

        menu.addItem(
            makeMenuItem(
                title: loc("menu.about"),
                action: #selector(openAbout(_:)),
                imageName: "info.circle",
                toolTip: loc("tooltip.menu.about")
            )
        )
        menu.addItem(makeMenuItem(title: loc("menu.quit"), action: #selector(quit(_:)), keyEquivalent: "q", imageName: "power"))

        statusItem.menu = menu
    }

    private func buildOtherSettingsMenu() -> NSMenu {
        let m = NSMenu()

        // 动画效果（Animation style）
        let animItem = makeMenuItem(title: loc("menu.animation"), imageName: "sparkles")
        let animMenu = NSMenu()
        let currentAnim = AppSettings.animationStyle
        for (title, key) in [(loc("menu.animation.dynamicIsland"), "dynamicIsland"),
                              (loc("menu.animation.minimal"),       "minimal"),
                              (loc("menu.animation.none"),          "none")] {
            animMenu.addItem(
                makeMenuItem(
                    title: title,
                    action: #selector(selectAnimation(_:)),
                    state: currentAnim == key ? .on : .off,
                    representedObject: key
                )
            )
        }
        let currentSpeed = AppSettings.animationSpeed
        animMenu.addItem(.separator())
        animMenu.addItem(makeSectionLabel(loc("menu.animation.speed")))
        for (title, key) in [(loc("menu.animation.slow"), "slow"),
                              (loc("menu.animation.medium"), "medium"),
                              (loc("menu.animation.fast"), "fast")] {
            animMenu.addItem(
                makeMenuItem(
                    title: title,
                    action: #selector(selectAnimSpeed(_:)),
                    state: currentSpeed == key ? .on : .off,
                    representedObject: key,
                    isEnabled: currentAnim == "dynamicIsland",
                    indentationLevel: 1
                )
            )
        }
        animItem.submenu = animMenu
        m.addItem(animItem)

        m.addItem(.separator())

        // 录音时降低系统音量（Lower system volume during recording）
        m.addItem(
            makeMenuItem(
                title: loc("menu.lowerVolumeOnRecording"),
                action: #selector(toggleLowerVolumeOnRecording(_:)),
                imageName: "speaker.wave.1",
                state: AppSettings.lowerVolumeOnRecording ? .on : .off,
                toolTip: loc("tooltip.menu.lowerVolumeOnRecording")
            )
        )

        // 开机启动（Launch at login）
        m.addItem(
            makeMenuItem(
                title: loc("menu.launchAtLogin"),
                action: #selector(toggleLaunchAtLogin(_:)),
                imageName: "power.circle",
                state: isLaunchAtLoginEnabled ? .on : .off,
                toolTip: loc("tooltip.menu.launchAtLogin")
            )
        )

        // 权限与帮助（Permissions & help）
        m.addItem(
            makeMenuItem(
                title: loc("menu.help"),
                action: #selector(openPermissions(_:)),
                imageName: hasAllPermissions ? "checkmark.shield" : "exclamationmark.shield",
                toolTip: loc("tooltip.menu.help")
            )
        )

        // 隐私政策（Privacy policy）
        m.addItem(makeMenuItem(title: loc("menu.privacyPolicy"), action: #selector(openPrivacyPolicy(_:)), imageName: "hand.raised"))

        m.addItem(.separator())

        #if !DEBUG_BUILD
        // 检查更新（Check for updates）
        m.addItem(makeMenuItem(title: loc("menu.checkForUpdates"), action: #selector(checkForUpdates(_:)), imageName: "arrow.down.circle"))
        m.addItem(
            makeMenuItem(
                title: loc("menu.betaUpdates"),
                action: #selector(toggleBetaUpdates(_:)),
                imageName: "flask",
                state: AppSettings.includeBetaUpdates ? .on : .off,
                indentationLevel: 1
            )
        )
        #endif

        m.addItem(makeMenuItem(title: loc("menu.rerunOOBE"), action: #selector(rerunOOBE(_:)), imageName: "sparkles.rectangle.stack"))

        #if DEBUG_BUILD
        m.addItem(.separator())

        // Debug: 测试离线模型下载提示弹窗（Debug: Test offline model download prompt）
        let testOnDeviceAlertItem = NSMenuItem(
            title: loc("menu.debug.testOnDeviceAlert"),
            action: #selector(debugTestOnDeviceAlert(_:)),
            keyEquivalent: ""
        )
        testOnDeviceAlertItem.image = icon("ladybug")
        testOnDeviceAlertItem.target = self
        m.addItem(testOnDeviceAlertItem)

        // Debug: 粘贴延迟可调（Debug: tunable paste delay）
        let pasteDelayItem = NSMenuItem(
            title: String(format: "Paste Delay: %.0f ms", AppSettings.pasteDelay * 1000),
            action: nil,
            keyEquivalent: ""
        )
        pasteDelayItem.image = icon("timer")
        let pasteDelaySubmenu = NSMenu()
        let current = AppSettings.pasteDelay
        for option in AppSettings.pasteDelayOptions {
            let sub = NSMenuItem(
                title: String(format: "%.0f ms", option * 1000),
                action: #selector(debugSelectPasteDelay(_:)),
                keyEquivalent: ""
            )
            sub.target = self
            sub.representedObject = option
            sub.state = abs(option - current) < 0.001 ? .on : .off
            pasteDelaySubmenu.addItem(sub)
        }
        pasteDelayItem.submenu = pasteDelaySubmenu
        m.addItem(pasteDelayItem)
        #endif

        return m
    }

    // MARK: - Launch at Login

    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private var hasAllPermissions: Bool {
        let currentEngine = AppSettings.normalizedRecognitionEngine
        let speechRequired = asrEngineRegistry.isApple(currentEngine)
        return permissionService.hasRequiredPermissions(speechRequired: speechRequired)
    }

    private static func supportsOnDeviceRecognition(for languageCode: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: languageCode))?.supportsOnDeviceRecognition == true
    }

    private func makeMenuItem(
        title: String,
        action: Selector? = nil,
        keyEquivalent: String = "",
        imageName: String? = nil,
        state: NSControl.StateValue = .off,
        representedObject: Any? = nil,
        isEnabled: Bool = true,
        indentationLevel: Int = 0,
        toolTip: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if action != nil {
            item.target = self
        }
        if let imageName {
            item.image = icon(imageName)
        }
        item.state = state
        item.representedObject = representedObject
        item.isEnabled = isEnabled
        item.indentationLevel = indentationLevel
        item.toolTip = toolTip
        return item
    }

    private func makeSectionLabel(_ title: String, indentationLevel: Int = 0, toolTip: String? = nil) -> NSMenuItem {
        makeMenuItem(
            title: title,
            isEnabled: false,
            indentationLevel: indentationLevel,
            toolTip: toolTip
        )
    }

    private func toggleAndRebuild(currentValue: Bool, update: (Bool) -> Void) {
        update(!currentValue)
        rebuildMenu()
    }

    private func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func statusBarIcon(accessibilityDescription: String) -> NSImage? {
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "atomvoice-status",
                                     withExtension: "svg",
                                     subdirectory: "Icons") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: accessibilityDescription)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = accessibilityDescription
        image?.size = NSSize(width: 17, height: 17)
        return image
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        AppSettings.selectedLanguage = code
        if AppSettings.appleOnDeviceRecognitionEnabled,
           !Self.supportsOnDeviceRecognition(for: code) {
            AppSettings.appleOnDeviceRecognitionEnabled = false
        }
        onLanguageChanged()
        rebuildMenu()
    }

    @objc private func selectRecognitionEngine(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }

        if asrEngineRegistry.isSherpa(code), !SherpaModelDownloader.isReady() {
            let alert = NSAlert()
            alert.messageText = loc("sherpa.download.title")
            alert.informativeText = loc("sherpa.download.message")
            alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            alert.addButton(withTitle: loc("sherpa.download.confirm"))
            alert.addButton(withTitle: loc("common.cancel"))
            if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
                AppSettings.recognitionEngine = code
                rebuildMenu()
                onSherpaDownloadRequested?()
            }
            return
        }

        if code == VolcengineASRSettings.engineCode {
            if !AppSettings.doubaoASRPrivacyAccepted {
                let alert = NSAlert()
                alert.messageText = loc("doubao.privacy.title")
                alert.informativeText = loc("doubao.privacy.message")
                alert.icon = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
                alert.addButton(withTitle: loc("doubao.privacy.continue"))
                alert.addButton(withTitle: loc("common.cancel"))
                guard AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn else { return }
                AppSettings.doubaoASRPrivacyAccepted = true
            }

            AppSettings.recognitionEngine = code
            rebuildMenu()
            if !VolcengineASRSettings.hasAPIKey {
                openDoubaoSettingsWindow()
            }
            return
        }

        AppSettings.recognitionEngine = code
        rebuildMenu()
    }

    @objc private func openSherpaFolder(_ sender: NSMenuItem) {
        SherpaOnnxRecognizerController.openSupportDirectory()
    }

    @objc private func openDoubaoSettings(_ sender: NSMenuItem) {
        openDoubaoSettingsWindow()
    }

    @objc private func openASRSettings(_ sender: NSMenuItem) {
        if asrSettingsWindow == nil {
            asrSettingsWindow = ASRSettingsWindowController()
        }
        asrSettingsWindow?.showWindow()
    }

    /// 公开方法：从 AppDelegate / OOBE 完成时调用（Public: called from AppDelegate / OOBE finish）
    func openDoubaoSettingsFromOutside() {
        openDoubaoSettingsWindow()
    }

    /// 公开方法：让外部触发菜单重建（Public: allow external menu rebuild）
    func rebuildMenuPublic() {
        rebuildMenu()
    }

    @objc private func rerunOOBE(_ sender: NSMenuItem) {
        // 重置完成标志并交给 AppDelegate 展示窗口
        // (Reset completion flag and let AppDelegate present the window)
        AppSettings.hasCompletedOOBE = false
        (NSApp.delegate as? AppDelegate)?.showOOBE()
    }

    private func openDoubaoSettingsWindow() {
        if doubaoSettingsWindow == nil {
            doubaoSettingsWindow = DoubaoSettingsWindowController()
        }
        doubaoSettingsWindow?.showWindow()
    }

    @objc private func toggleAppleOnDeviceSpeech(_ sender: NSMenuItem) {
        let currentLang = AppSettings.selectedLanguage
        guard Self.supportsOnDeviceRecognition(for: currentLang) else {
            showOnDeviceModelDownloadAlert()
            AppSettings.appleOnDeviceRecognitionEnabled = false
            rebuildMenu()
            return
        }
        toggleAndRebuild(currentValue: AppSettings.appleOnDeviceRecognitionEnabled) {
            AppSettings.appleOnDeviceRecognitionEnabled = $0
        }
    }

    /// 弹窗提示用户下载离线语音模型（Show alert prompting user to download offline speech model）
    private func showOnDeviceModelDownloadAlert() {
        let alert = NSAlert()
        alert.messageText = loc("alert.onDeviceModel.title")
        alert.informativeText = loc("alert.onDeviceModel.message")
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("alert.onDeviceModel.openSettings"))
        alert.addButton(withTitle: loc("common.cancel"))

        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    #if DEBUG_BUILD
    @objc private func debugTestOnDeviceAlert(_ sender: NSMenuItem) {
        showOnDeviceModelDownloadAlert()
    }

    @objc private func debugSelectPasteDelay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        AppSettings.pasteDelay = value
        DebugLog.info("[Debug] Paste delay 调整为 \(value)s")
    }
    #endif

    @objc private func openEngineHowto(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = loc("menu.engine.howto")
        alert.icon = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        alert.accessoryView = makeEngineHowtoTextView()
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

    private func makeEngineHowtoTextView() -> NSView {
        let text = loc("engine.howto.message")
        let width: CGFloat = 660
        let height: CGFloat = 430

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 32, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(makeEngineHowtoAttributedString(text))

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(usedHeight)))
        }

        scrollView.documentView = textView
        return scrollView
    }

    private func makeEngineHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 2
        headingParagraph.paragraphSpacing = 6
        headingParagraph.lineBreakMode = .byWordWrapping

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 7
        bodyParagraph.lineBreakMode = .byWordWrapping

        let summaryParagraph = NSMutableParagraphStyle()
        summaryParagraph.lineSpacing = 3
        summaryParagraph.paragraphSpacing = 0
        summaryParagraph.lineBreakMode = .byWordWrapping

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let summaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: summaryParagraph,
        ]

        let summaryPrefixes = ["建议", "建議", "Recommendation", "おすすめ", "추천", "Recomendación", "Recommandation", "Empfehlung"]
        var previousLineWasBlank = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousLineWasBlank, result.length > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                previousLineWasBlank = true
                continue
            }

            let attributes: [NSAttributedString.Key: Any]
            if line.hasPrefix("• ") {
                attributes = headingAttributes
            } else if summaryPrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = summaryAttributes
            } else {
                attributes = bodyAttributes
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
            previousLineWasBlank = false
        }

        return result
    }

    private func makeLLMHowtoAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: .newlines)

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineSpacing = 2
        headingParagraph.paragraphSpacing = 6
        headingParagraph.lineBreakMode = .byWordWrapping

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 7
        bodyParagraph.lineBreakMode = .byWordWrapping

        let listParagraph = NSMutableParagraphStyle()
        listParagraph.lineSpacing = 3
        listParagraph.paragraphSpacing = 4
        listParagraph.lineBreakMode = .byWordWrapping
        listParagraph.headIndent = 20
        listParagraph.firstLineHeadIndent = 0

        let noteParagraph = NSMutableParagraphStyle()
        noteParagraph.lineSpacing = 3
        noteParagraph.paragraphSpacing = 0
        noteParagraph.lineBreakMode = .byWordWrapping

        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let listAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: listParagraph,
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: noteParagraph,
        ]

        let headingPrefixes = ["LLM", "例如", "使用方法", "For example", "How to use", "例", "使い方", "예", "사용 방법"]
        let notePrefixes = ["开启后", "When enabled", "有効にすると", "활성화하면"]
        var previousLineWasBlank = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousLineWasBlank, result.length > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                previousLineWasBlank = true
                continue
            }

            let attributes: [NSAttributedString.Key: Any]
            if headingPrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = headingAttributes
            } else if notePrefixes.contains(where: { line.hasPrefix($0) }) {
                attributes = noteAttributes
            } else if line.hasPrefix("1.") || line.hasPrefix("2.") || line.hasPrefix("3.") || line.hasPrefix("4.") {
                attributes = listAttributes
            } else {
                attributes = bodyAttributes
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
            previousLineWasBlank = false
        }

        return result
    }

    @objc private func selectTriggerKey(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let keyCode = UInt16(num.intValue)
        AppSettings.triggerKeyCode = keyCode
        onTriggerKeyChanged?(keyCode)
        rebuildMenu()
    }

    @objc private func selectAudioInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        AppSettings.audioInputDeviceUID = uid
        rebuildMenu()
    }

    @objc private func selectAnimation(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        AppSettings.animationStyle = style
        rebuildMenu()
    }

    @objc private func selectAnimSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? String else { return }
        AppSettings.animationSpeed = speed
        rebuildMenu()
    }

    @objc private func selectInputModeTap(_ sender: NSMenuItem) {
        AppSettings.silenceAutoStopEnabled = true
        rebuildMenu()
    }

    @objc private func selectInputModeHold(_ sender: NSMenuItem) {
        AppSettings.silenceAutoStopEnabled = false
        rebuildMenu()
    }

    @objc private func toggleAppleLiveInsertion(_ sender: NSMenuItem) {
        toggleAndRebuild(currentValue: AppSettings.appleLiveInsertionEnabled) {
            AppSettings.appleLiveInsertionEnabled = $0
        }
    }

    @objc private func selectSilenceDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Double else { return }
        AppSettings.silenceDuration = duration
        AppSettings.tapModeManualStop = false
        rebuildMenu()
    }

    @objc private func selectManualStop(_ sender: NSMenuItem) {
        AppSettings.tapModeManualStop = true
        rebuildMenu()
    }

    @objc private func selectSteadyNoiseSensitivity(_ sender: NSMenuItem) {
        guard let sensitivity = sender.representedObject as? Int else { return }
        AppSettings.steadyNoiseSensitivity = sensitivity
        rebuildMenu()
    }

    @objc private func selectTextOutputSink(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: TextOutputSinkRegistry.userDefaultsKey)
        rebuildMenu()
    }

    @objc private func togglePunctuation(_ sender: NSMenuItem) {
        toggleAndRebuild(currentValue: AppSettings.autoPunctuationEnabled) {
            AppSettings.autoPunctuationEnabled = $0
        }
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        toggleAndRebuild(currentValue: AppSettings.llmEnabled) {
            AppSettings.llmEnabled = $0
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(llmRefiner: llmRefiner)
        }
        settingsWindow?.showWindow()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if isLaunchAtLoginEnabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                DebugLog.error("[LaunchAtLogin] Error: \(error)")
            }
        }
        rebuildMenu()
    }

    @objc private func toggleLowerVolumeOnRecording(_ sender: NSMenuItem) {
        toggleAndRebuild(currentValue: AppSettings.lowerVolumeOnRecording) {
            AppSettings.lowerVolumeOnRecording = $0
        }
    }

    @objc private func openPermissions(_ sender: NSMenuItem) {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController() }
        permissionsWindow?.showWindow()
    }

    @objc private func openPrivacyPolicy(_ sender: NSMenuItem) {
        let lang = Locale.preferredLanguages.first ?? "en"
        let file: String
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
            file = "PRIVACY-zh-Hant.md"
        } else if lang.hasPrefix("zh") {
            file = "PRIVACY-zh-Hans.md"
        } else if lang.hasPrefix("ja") {
            file = "PRIVACY-ja.md"
        } else if lang.hasPrefix("ko") {
            file = "PRIVACY-ko.md"
        } else if lang.hasPrefix("es") {
            file = "PRIVACY-es.md"
        } else if lang.hasPrefix("fr") {
            file = "PRIVACY-fr.md"
        } else if lang.hasPrefix("de") {
            file = "PRIVACY-de.md"
        } else {
            file = "PRIVACY-en.md"
        }
        let url = URL(string: "https://github.com/BlackSquarre/AtomVoice/blob/main/README/privacy/\(file)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleBetaUpdates(_ sender: NSMenuItem) {
        toggleAndRebuild(currentValue: AppSettings.includeBetaUpdates) {
            AppSettings.includeBetaUpdates = $0
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        UpdateChecker.shared.checkForUpdates(silent: false)
    }

    @objc private func openLLMHowto(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = loc("menu.llm.howto")
        alert.icon = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        alert.accessoryView = makeLLMHowtoTextView()
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

    private func makeLLMHowtoTextView() -> NSView {
        let text = loc("llm.howto.message")
        let width: CGFloat = 560
        let height: CGFloat = 380

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 32, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(makeLLMHowtoAttributedString(text))

        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(usedHeight)))
        }

        scrollView.documentView = textView
        return scrollView
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        if aboutWindow == nil { aboutWindow = AboutWindowController() }
        aboutWindow?.showWindow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func showAccessibilityWarning() {
        statusItem.button?.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: loc("accessibility.warning.title"))
        let alert = NSAlert()
        alert.messageText = loc("accessibility.warning.title")
        alert.informativeText = loc("accessibility.warning.message")
        alert.addButton(withTitle: loc("accessibility.openSettings"))
        alert.addButton(withTitle: loc("accessibility.ignore"))
        if AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn {
            permissionService.openSettings(for: .accessibility)
        }
        statusItem.button?.image = Self.statusBarIcon(accessibilityDescription: loc("app.title"))
    }
}
