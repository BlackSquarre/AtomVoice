import Cocoa

final class ASRSettingsWindowController: NSObject {
    private static let initialContentSize = NSSize(width: 640, height: 600)

    var onClose: (() -> Void)?
    private weak var sherpaDownloadReporter: SherpaDownloadReporting?
    private var window: NSWindow?
    private var tabView: NSTabView!

    init(sherpaDownloadReporter: SherpaDownloadReporting?) {
        self.sherpaDownloadReporter = sherpaDownloadReporter
        super.init()
    }

    private lazy var sherpaTab = SherpaSettingsTab(
        parentWindow: { [weak self] in self?.window },
        onStatusChanged: { [weak self] message, color in
            self?.statusLabel.stringValue = message
            self?.statusLabel.textColor = color
        },
        sherpaDownloadReporter: sherpaDownloadReporter
    )
    private let appleTab = AppleSettingsTab()
    private lazy var doubaoTab = DoubaoSettingsTab(textFieldDelegate: self)

    // 状态（Status）
    private var statusLabel: NSTextField!

    func showWindow() {
        if let window {
            refreshFields()
            WindowPresenter.shared.bringToFront(window)
            return
        }
        buildWindow()
    }

    #if DEBUG_BUILD
    func showWindowForSnapshot(tabIdentifier: String) {
        if window == nil {
            buildWindow()
        }
        selectTab(identifier: tabIdentifier)
        window?.setContentSize(Self.initialContentSize)
        window?.makeKeyAndOrderFront(nil)
    }
    #endif

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("asrSettings.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 600, height: 520)

        guard let cv = w.contentView else { return }
        let pad: CGFloat = 24

        // 创建 TabView（Create TabView）
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        // 标签页 1：Sherpa 本地识别（Tab 1: Sherpa local recognition）
        let sherpaTab = NSTabViewItem(identifier: "sherpa")
        sherpaTab.label = loc("asrSettings.tab.sherpa")
        sherpaTab.view = self.sherpaTab.makeView()
        tabView.addTabViewItem(sherpaTab)

        // 标签页 2：Apple 离线识别（Tab 2: Apple offline recognition）
        let appleTab = NSTabViewItem(identifier: "apple")
        appleTab.label = loc("asrSettings.tab.apple")
        appleTab.view = self.appleTab.makeView()
        tabView.addTabViewItem(appleTab)

        // 标签页 3：豆包云端识别（Tab 3: Doubao cloud recognition）
        let doubaoTab = NSTabViewItem(identifier: "doubao")
        doubaoTab.label = loc("asrSettings.tab.doubao")
        doubaoTab.view = self.doubaoTab.makeView()
        tabView.addTabViewItem(doubaoTab)

        // 底部按钮（Bottom buttons）
        statusLabel = SettingsUI.makeSecondaryLabel()

        let cancelBtn = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let saveBtn = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [cancelBtn, saveBtn])

        // 布局（Layout）
        cv.addSubview(tabView)
        cv.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),

            bottomRow.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 16),
            bottomRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            bottomRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            bottomRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),
        ])

        window = w
        refreshFields()

        // 默认显示当前选中的识别引擎对应的标签页
        // (Default to the tab matching the currently selected ASR engine)
        let currentEngine = AppSettings.normalizedRecognitionEngine
        let tabIdentifier: String
        switch currentEngine {
        case VolcengineASRSettings.engineCode: tabIdentifier = "doubao"
        case ASREngineRegistry.sherpaCode: tabIdentifier = "sherpa"
        default: tabIdentifier = "apple"
        }
        let tabIndex = tabView.indexOfTabViewItem(withIdentifier: tabIdentifier)
        if tabIndex != NSNotFound {
            tabView.selectTabViewItem(at: tabIndex)
        }

        w.setContentSize(Self.initialContentSize)
        let restoredFrame = WindowConfiguration.configureRestorableSettingsWindow(w, identifier: "AtomVoice.ASRSettingsWindow")
        if !restoredFrame {
            w.center()
        }
        WindowPresenter.shared.bringToFront(w)
    }

    private func selectTab(identifier: String) {
        let tabIndex = tabView.indexOfTabViewItem(withIdentifier: identifier)
        if tabIndex != NSNotFound {
            tabView.selectTabViewItem(at: tabIndex)
        }
    }

    // MARK: - 辅助方法（Helper methods）

    private func refreshFields() {
        // 豆包设置（Doubao settings）
        doubaoTab.refresh()

        // Sherpa 设置（Sherpa settings）
        sherpaTab.refresh()

        // Apple 设置（Apple settings）
        appleTab.refresh()

        // 状态（Status）
        statusLabel?.stringValue = ""
    }

    @objc private func saveSettings(_ sender: NSButton) {
        // 保存豆包设置（Save Doubao settings）
        switch doubaoTab.save() {
        case .saved, .deferred:
            break
        case let .failed(message, color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
            return
        }

        // 保存 Sherpa 设置（Save Sherpa settings）
        switch sherpaTab.save() {
        case .saved:
            break
        case let .failed(message, color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
            return
        case .deferred:
            _ = appleTab.save()
            return
        }

        // 保存 Apple 设置（Save Apple settings）
        switch appleTab.save() {
        case .saved, .deferred:
            break
        case let .failed(message, color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
            return
        }

        statusLabel.stringValue = loc("settings.saved")
        statusLabel.textColor = .systemGreen
        window?.close()
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}

// MARK: - NSTabViewDelegate

extension ASRSettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // 标签页切换时刷新（Refresh when switching tabs）
        refreshFields()
    }
}

// MARK: - NSWindowDelegate

extension ASRSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        onClose?()
    }
}

// MARK: - NSTextFieldDelegate

extension ASRSettingsWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
