import Cocoa

protocol UpdatePresenting: AnyObject {
    func confirmDownload(version: String, currentVersion: String, isPreRelease: Bool, isDebugBuild: Bool) -> Bool
    func confirmRestart(version: String) -> Bool
    func showProgress(_ message: String)
    func updateProgressLabel(_ message: String)
    func closeProgress()
    func bringProgressToFront()
    func showAlert(title: String, message: String)
    func terminateApplication()
}

/// 更新呈现与平台动作；更新状态和阶段资源由 Checker 持有。
final class AppKitUpdatePresenter: UpdatePresenting {
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    func confirmDownload(version: String, currentVersion: String, isPreRelease: Bool, isDebugBuild: Bool) -> Bool {
        let badges = [isPreRelease ? loc("update.beta") : nil,
                      isDebugBuild ? loc("update.debug") : nil].compactMap { $0 }
        let displayVersion = badges.isEmpty ? version : "\(version) (\(badges.joined(separator: ", ")))"
        let alert = NSAlert()
        alert.messageText = loc("update.available.title")
        alert.informativeText = loc("update.available.message", displayVersion, currentVersion)
        alert.addButton(withTitle: loc("update.install"))
        alert.addButton(withTitle: loc("update.later"))
        return AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn
    }

    func confirmRestart(version: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = loc("update.done.title")
        alert.informativeText = loc("update.done.message", version)
        alert.addButton(withTitle: loc("update.restart"))
        alert.addButton(withTitle: loc("update.later"))
        NSApp.activate(ignoringOtherApps: true)
        let attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        defer { NSApp.cancelUserAttentionRequest(attentionRequest) }
        return AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn
    }

    func bringProgressToFront() { progressWindow?.makeKeyAndOrderFront(nil) }
    func terminateApplication() { NSApp.terminate(nil) }

    // MARK: - 进度窗口

    func showProgress(_ message: String) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = loc("update.progress.title")
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false

        let cv = w.contentView!

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        progressLabel = label

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.startAnimation(nil)

        cv.addSubview(label)
        cv.addSubview(bar)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cv.topAnchor, constant: 22),
            label.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
        ])

        progressWindow = w
        w.center()
        WindowPresenter.shared.bringToFront(w)
    }

    func updateProgressLabel(_ message: String) {
        progressLabel?.stringValue = message
    }

    func closeProgress() {
        if let w = progressWindow {
            w.close()
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        progressWindow = nil
        progressLabel = nil
    }

    // MARK: - 辅助

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

}
