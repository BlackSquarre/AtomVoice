import Cocoa

/// 独立入口复用 ASR 设置中的豆包页面，服务切换和凭据草稿保持一致。
final class DoubaoSettingsWindowController: NSObject {
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private lazy var settingsTab = DoubaoSettingsTab(textFieldDelegate: self)
    private var statusLabel: NSTextField!

    func showWindow() {
        if let window {
            WindowPresenter.shared.bringToFront(window)
            return
        }
        buildWindow()
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = loc("doubao.settings.title")
        w.minSize = NSSize(width: 640, height: 560)
        w.isReleasedWhenClosed = false
        w.delegate = self
        guard let contentView = w.contentView else { return }

        let page = settingsTab.makeView()
        page.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = SettingsUI.makeSecondaryLabel()
        let cancel = SettingsUI.makeButton(loc("settings.cancel"), target: self, action: #selector(cancelSettings(_:)))
        let save = SettingsUI.makeButton(loc("settings.save"), target: self, action: #selector(saveSettings(_:)))
        save.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let bottomRow = SettingsUI.makeBottomRow(statusLabel: statusLabel, buttons: [cancel, save])
        contentView.addSubview(page)
        contentView.addSubview(bottomRow)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            page.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            page.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            page.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -16),
            bottomRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            bottomRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            bottomRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
        window = w
        settingsTab.refresh()
        let restored = WindowConfiguration.configureRestorableSettingsWindow(w, identifier: "AtomVoice.DoubaoSettingsWindow")
        // 旧窗口保存的尺寸可能不足以显示新增的服务说明。
        if w.contentLayoutRect.width < 640 || w.contentLayoutRect.height < 560 {
            w.setContentSize(NSSize(width: 640, height: 560))
        }
        if !restored { w.center() }
        WindowPresenter.shared.bringToFront(w)
    }

    @objc private func saveSettings(_ sender: NSButton) {
        switch settingsTab.save() {
        case .saved:
            window?.close()
        case .failed(let message, let color):
            statusLabel.stringValue = message
            statusLabel.textColor = color
        case .deferred:
            break
        }
    }

    @objc private func cancelSettings(_ sender: NSButton) {
        window?.close()
    }
}

extension DoubaoSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowPresenter.shared.resetActivationIfNeeded(closing: window)
        }
        onClose?()
    }
}

extension DoubaoSettingsWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.selectNextKeyView(nil)
            return true
        }
        return false
    }
}
