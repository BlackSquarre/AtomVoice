import Cocoa

/// 外观页即时写入唯一 App 偏好；预览只生成演示能量，不创建采集或识别对象。
final class PreferencesAppearancePane: NSObject {
    private let interfaceSettings: InterfaceSettings
    private let appliesApplicationAppearance: Bool
    private var onSizeChanged: (() -> Void)?
    private var onChanged: (() -> Void)?
    private var appearanceButtons: [NSButton] = []
    private weak var styleControl: NSPopUpButton?
    private weak var speedControl: NSPopUpButton?
    private weak var preview: PreferencesCapsulePreviewView?

    init(
        interfaceSettings: InterfaceSettings = AppSettings.interface,
        appliesApplicationAppearance: Bool = true
    ) {
        self.interfaceSettings = interfaceSettings
        self.appliesApplicationAppearance = appliesApplicationAppearance
        super.init()
    }

    func makeView(
        onSizeChanged: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) -> NSView {
        self.onSizeChanged = onSizeChanged
        self.onChanged = onChanged
        appearanceButtons = AppearancePreference.allCases.enumerated().map { index, preference in
            let button = NSButton(radioButtonWithTitle: preference.displayName, target: self, action: #selector(changeAppearance(_:)))
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("appearance-" + preference.rawValue)
            button.state = preference == interfaceSettings.appearanceMode ? .on : .off
            return button
        }
        let appearance = NSStackView(views: appearanceButtons)
        appearance.orientation = .horizontal
        appearance.alignment = .centerY
        appearance.distribution = .fill
        appearance.spacing = 12
        let style = popup(
            options: [
                ("dynamicIsland", loc("menu.animation.dynamicIsland")),
                ("minimal", loc("menu.animation.minimal")),
                ("none", loc("menu.animation.none")),
            ],
            selected: interfaceSettings.animationStyle,
            action: #selector(changeStyle(_:))
        )
        let speed = popup(
            options: [
                ("slow", loc("menu.animation.slow")),
                ("medium", loc("menu.animation.medium")),
                ("fast", loc("menu.animation.fast")),
            ],
            selected: interfaceSettings.animationSpeed,
            action: #selector(changeSpeed(_:))
        )
        speed.isEnabled = interfaceSettings.animationStyle == "dynamicIsland"
        styleControl = style
        speedControl = speed
        let preview = PreferencesCapsulePreviewView()
        preview.configure(style: interfaceSettings.animationStyle, speed: interfaceSettings.animationSpeed)
        self.preview = preview
        return PreferencesLayout.column([
            PreferencesLayout.group(rows: [
                PreferencesLayout.row(title: loc("preferences.appearance.mode"), control: appearance),
            ]),
            PreferencesLayout.group(title: loc("preferences.appearance.capsule"), rows: [
                PreferencesLayout.row(title: loc("menu.animation"), control: style),
                PreferencesLayout.row(title: loc("menu.animation.speed"), control: speed),
            ]),
            preview,
        ])
    }

    private func popup(
        options: [(value: String, title: String)], selected: String, action: Selector
    ) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = action
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let index = options.firstIndex(where: { $0.value == selected }) { popup.selectItem(at: index) }
        return popup
    }

    @objc private func changeAppearance(_ sender: NSButton) {
        guard AppearancePreference.allCases.indices.contains(sender.tag) else { return }
        for button in appearanceButtons { button.state = button === sender ? .on : .off }
        interfaceSettings.appearanceMode = AppearancePreference.allCases[sender.tag]
        if appliesApplicationAppearance {
            AppearancePreference.applyToApplication(interfaceSettings.appearanceMode)
        } else {
            // 快照只改当前预览窗口；不触碰 NSApp 外观或标准 UserDefaults。
            sender.window?.appearance = interfaceSettings.appearanceMode.appKitAppearance
        }
        onChanged?()
    }

    @objc private func changeStyle(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        interfaceSettings.animationStyle = value
        speedControl?.isEnabled = value == "dynamicIsland"
        preview?.configure(style: value, speed: interfaceSettings.animationSpeed)
        onChanged?()
        onSizeChanged?()
    }

    @objc private func changeSpeed(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        interfaceSettings.animationSpeed = value
        preview?.configure(style: interfaceSettings.animationStyle, speed: value)
        onChanged?()
    }
}

/// 五频段沿用生产 WaveformView；42pt 高、21pt 圆角及间距来自 CapsuleWindow。
private final class PreferencesCapsulePreviewView: NSView {
    private let waveform = WaveformView(frame: .zero)
    private let capsule: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            CapsuleGlassAppearance.configure(glass)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        return effect
    }()
    private var energyTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var style = AppSettings.defaultAnimationStyle
    private var speed = AppSettings.defaultAnimationSpeed

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let stage = NSBox()
        stage.boxType = .custom
        stage.titlePosition = .noTitle
        stage.borderType = .noBorder
        stage.fillColor = .underPageBackgroundColor
        stage.cornerRadius = 8
        stage.contentViewMargins = .zero
        stage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 21
        capsule.layer?.cornerCurve = .continuous
        capsule.layer?.masksToBounds = true
        addSubview(capsule)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        let capsuleContent: NSView
        if #available(macOS 26.0, *), let glass = capsule as? NSGlassEffectView {
            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            capsuleContent = content
        } else {
            capsuleContent = capsule
        }
        capsuleContent.addSubview(waveform)
        // 与网页及生产最小胶囊同宽，保留空文字区域，不添加虚构的识别文本。
        let preferredWidth = capsule.widthAnchor.constraint(equalToConstant: 236)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 112),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 42),
            capsule.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            waveform.leadingAnchor.constraint(equalTo: capsuleContent.leadingAnchor, constant: 24 + 8),
            waveform.centerYAnchor.constraint(equalTo: capsuleContent.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 24),
            waveform.heightAnchor.constraint(equalToConstant: 29),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(loc("preferences.appearance.preview"))
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        stopPreview()
        removeObservers()
    }

    func configure(style: String, speed: String) {
        self.style = style
        self.speed = speed
        // “无”不显示输入胶囊；同时从设置列移除预览占位并停止五线更新。
        capsule.isHidden = style == "none"
        isHidden = style == "none"
        stopPreview()
        synchronizeAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        stopPreview()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
                observe(name, center: .default, object: window)
            }
            observe(NSWindow.willCloseNotification, center: .default, object: window, closing: true)
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, center: .default, object: clip)
            }
            observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter)
        }
        synchronizeAnimation()
    }

    override func layout() {
        super.layout()
        synchronizeAnimation()
    }

    private var canAnimate: Bool {
        guard style != "none", let window, window.isVisible, window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func synchronizeAnimation() {
        guard canAnimate else { stopPreview(); return }
        guard energyTimer == nil else { return }
        waveform.restartAnimating()
        updateEnergy()
        let timer = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.canAnimate else { self.stopPreview(); return }
            self.updateEnergy()
        }
        energyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        animateEntrance()
    }

    private func updateEnergy() {
        let strength = Float.random(in: 0.12...0.82)
        waveform.updateBands((0..<WaveformEnvelope.bandCount).map { _ in strength * Float.random(in: 0.5...1) })
    }

    private func animateEntrance() {
        guard style != "none", let layer = capsule.layer else { return }
        let motion = CapsuleSpotlightMotion.resolve(speedCode: speed)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = style == "minimal" ? [0.92, 1] : [motion.inScale, motion.overshootScale, motion.settleScale, 1]
        scale.keyTimes = style == "minimal" ? [0, 1] : [0, 0.58, 0.82, 1]
        scale.duration = style == "minimal" ? 0.2 : motion.scaleIn
        layer.add(scale, forKey: "preferences.preview.entrance")
    }

    private func stopPreview() {
        energyTimer?.invalidate()
        energyTimer = nil
        waveform.stopAnimating()
        capsule.layer?.removeAnimation(forKey: "preferences.preview.entrance")
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter,
        object: AnyObject? = nil,
        closing: Bool = false
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            if closing { self?.stopPreview() } else { self?.synchronizeAnimation() }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
