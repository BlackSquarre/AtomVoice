import Cocoa

/// 自动更新协调器：维护检查/下载/重启的状态机和 UI，把网络 I/O 委托给 ReleaseSource，
/// 把文件/签名/安装委托给 UpdateInstaller。
/// (Auto-update coordinator: owns the check/download/restart state machine and UI;
/// delegates network I/O to ReleaseSource and file/signature/install to UpdateInstaller.)
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    private let bundleIdentifier = "com.blacksquarre.AtomVoice"
    private let teamIdentifier = "NC623693G3"
    private let releaseSource: ReleaseSource
    private let installer: UpdateInstaller

    private convenience override init() {
        let installer = BundleUpdateInstaller(
            expectedBundleIdentifier: "com.blacksquarre.AtomVoice",
            expectedTeamIdentifier: "NC623693G3",
            isNewer: { lhs, rhs in
                // 与 UpdateChecker.isNewer 共用同一算法。
                // (Reuses the same algorithm as UpdateChecker.isNewer.)
                UpdateChecker.isNewer(lhs, than: rhs)
            }
        )
        self.init(
            releaseSource: GitHubReleaseSource(owner: "BlackSquarre", repo: "AtomVoice"),
            installer: installer
        )
    }

    init(releaseSource: ReleaseSource, installer: UpdateInstaller) {
        self.releaseSource = releaseSource
        self.installer = installer
        super.init()
    }

    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private enum UpdateState {
        case idle
        case checking
        case prompting
        case downloading
        case readyToRestart
        case applying
    }
    private var state: UpdateState = .idle
    private var pendingUserVisibleCheck = false
    private var pendingRestartPrompt: (version: String, newAppURL: URL)?
    var shouldDeferRestartPrompt: (() -> Bool)?

    // MARK: - 公开 API

    /// 检查更新（Check for updates）
    /// - Parameter silent: true = 无新版时不弹提示，启动时后台静默检查用。
    /// (true = no alert when up-to-date, for silent background check on launch.)
    func checkForUpdates(silent: Bool = false) {
        guard state == .idle else {
            if state == .checking, !silent {
                pendingUserVisibleCheck = true
            }
            if !silent {
                progressWindow?.makeKeyAndOrderFront(nil)
            }
            return
        }

        state = .checking
        pendingUserVisibleCheck = !silent

        let includeBeta = AppSettings.includeBetaUpdates
        #if DEBUG_BUILD
        let preferDebugBuild = AppSettings.updateToDebugBuilds
        #else
        let preferDebugBuild = false
        #endif
        releaseSource.fetchLatestRelease(includeBeta: includeBeta, preferDebugBuild: preferDebugBuild) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state == .checking else { return }
                let shouldShowResult = self.pendingUserVisibleCheck
                self.pendingUserVisibleCheck = false

                switch result {
                case .failure(let err):
                    self.state = .idle
                    if shouldShowResult {
                        self.showAlert(title: loc("update.error.title"),
                                       message: loc("update.error.fetch", err.localizedDescription))
                    }
                case .success(let release):
                    self.handleRelease(release, silent: !shouldShowResult)
                }
            }
        }
    }

    func resumeDeferredRestartPromptIfPossible() {
        guard state == .readyToRestart,
              let pendingRestartPrompt,
              shouldDeferRestartPrompt?() != true else { return }

        self.pendingRestartPrompt = nil
        showRestartPrompt(version: pendingRestartPrompt.version, newAppURL: pendingRestartPrompt.newAppURL)
    }

    // MARK: - 版本比对与提示

    private func handleRelease(_ release: ReleaseInfo, silent: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(release.version, than: current) else {
            state = .idle
            if !silent {
                showAlert(title: loc("update.upToDate.title"),
                          message: loc("update.upToDate.message", current))
            }
            return
        }

        let badges = [
            release.isPreRelease ? loc("update.beta") : nil,
            release.isDebugBuild ? loc("update.debug") : nil,
        ].compactMap { $0 }
        let displayVersion = badges.isEmpty
            ? release.version
            : "\(release.version) (\(badges.joined(separator: ", ")))"

        let alert = NSAlert()
        alert.messageText = loc("update.available.title")
        alert.informativeText = loc("update.available.message", displayVersion, current)
        alert.addButton(withTitle: loc("update.install"))
        alert.addButton(withTitle: loc("update.later"))
        state = .prompting
        guard AlertPresenter.shared.runModalAlert(alert) == .alertFirstButtonReturn else {
            state = .idle
            return
        }
        startDownload(release)
    }

    // MARK: - 下载

    private func startDownload(_ release: ReleaseInfo) {
        guard state == .prompting else { return }
        state = .downloading
        showProgress(loc("update.downloading", release.version))

        releaseSource.downloadAsset(release) { [weak self] downloadResult in
            DispatchQueue.main.async {
                guard let self else { return }
                switch downloadResult {
                case .failure(let error):
                    self.closeProgress()
                    self.state = .idle
                    self.showAlert(title: loc("update.error.title"),
                                   message: loc("update.error.download", error.localizedDescription))
                case .success(let tmpURL):
                    self.updateProgressLabel(loc("update.verifying"))
                    self.verifyAndInstall(zipURL: tmpURL, release: release)
                }
            }
        }
    }

    private func verifyAndInstall(zipURL: URL, release: ReleaseInfo) {
        releaseSource.fetchChecksumsListing(for: release) { [weak self] listingResult in
            guard let self else { return }
            switch listingResult {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.closeProgress()
                    self.state = .idle
                    self.showAlert(title: loc("update.error.title"),
                                   message: loc("update.error.install", "Failed to fetch SHA256SUMS.txt: \(error.localizedDescription)"))
                }
            case .success(let listing):
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.installer.verifyChecksum(zipURL: zipURL, listing: listing, assetName: release.assetName)
                        DispatchQueue.main.async { self.updateProgressLabel(loc("update.installing")) }
                        let newApp = try self.installer.extractZip(zipURL)
                        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                        try self.installer.validateDownloadedApp(newApp, currentVersion: current, expectedVersion: release.version)
                        DispatchQueue.main.async {
                            guard self.state == .downloading else { return }
                            self.closeProgress()
                            self.promptRestart(version: release.version, newAppURL: newApp)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.closeProgress()
                            self.state = .idle
                            self.showAlert(title: loc("update.error.title"),
                                           message: loc("update.error.install", error.localizedDescription))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 安装与重启

    private func promptRestart(version: String, newAppURL: URL) {
        guard state == .downloading else { return }
        state = .readyToRestart
        if shouldDeferRestartPrompt?() == true {
            pendingRestartPrompt = (version: version, newAppURL: newAppURL)
            return
        }
        showRestartPrompt(version: version, newAppURL: newAppURL)
    }

    private func showRestartPrompt(version: String, newAppURL: URL) {
        guard state == .readyToRestart else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = loc("update.done.title")
        alert.informativeText = loc("update.done.message", version)
        alert.addButton(withTitle: loc("update.restart"))
        alert.addButton(withTitle: loc("update.later"))

        // 强提醒：抢占前台 + Dock 跳动直到用户响应。
        // (Strong attention: come to foreground + bounce Dock until the user responds.)
        NSApp.activate(ignoringOtherApps: true)
        let attentionRequest = NSApp.requestUserAttention(.criticalRequest)

        let response = AlertPresenter.shared.runModalAlert(alert)
        NSApp.cancelUserAttentionRequest(attentionRequest)
        if response == .alertFirstButtonReturn {
            applyAndRelaunch(newAppURL: newAppURL)
        } else {
            state = .idle
        }
    }

    private func applyAndRelaunch(newAppURL: URL) {
        guard state == .readyToRestart else { return }
        state = .applying
        do {
            try installer.applyAndRelaunch(newAppURL: newAppURL, currentBundlePath: Bundle.main.bundlePath)
            NSApp.terminate(nil)
        } catch {
            state = .readyToRestart
            showAlert(title: loc("update.error.title"),
                      message: loc("update.error.install", error.localizedDescription))
        }
    }

    // MARK: - 进度窗口

    private func showProgress(_ message: String) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = loc("app.title")
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

    private func updateProgressLabel(_ message: String) {
        progressLabel?.stringValue = message
    }

    private func closeProgress() {
        if let w = progressWindow {
            w.close()
            WindowPresenter.shared.resetActivationIfNeeded(closing: w)
        }
        progressWindow = nil
        progressLabel = nil
    }

    // MARK: - 辅助

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: loc("common.ok"))
        AlertPresenter.shared.runModalAlert(alert)
    }

    struct ParsedVersion {
        let numbers: [Int]
        let preRelease: [String]?
    }

    /// 解析版本号，兼容 GitHub tag 的 "0.10.1-Beta-2" 和 Info.plist 的 "0.10.1 Beta 2"。
    /// (Parse version string; tolerates both GitHub tag "0.10.1-Beta-2" and Info.plist "0.10.1 Beta 2" forms.)
    func parseVersion(_ version: String) -> ParsedVersion {
        Self.parseVersion(version)
    }

    static func parseVersion(_ version: String) -> ParsedVersion {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("v") {
            normalized.removeFirst()
        }

        var base = ""
        var suffix = ""
        var hasReachedSuffix = false
        for char in normalized {
            if !hasReachedSuffix, char.isNumber || char == "." {
                base.append(char)
            } else {
                hasReachedSuffix = true
                suffix.append(char)
            }
        }

        let numbers = base.split(separator: ".").map { Int($0) ?? 0 }
        let preRelease = suffix
            .lowercased()
            .split { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" }
            .map(String.init)
        return ParsedVersion(numbers: numbers, preRelease: preRelease.isEmpty ? nil : preRelease)
    }

    /// 比较两个版本号。规则：基础版本号更大 → 更新；基础相同时 stable > pre-release；pre-release 按标识符比较。
    /// (Compare two version numbers. Rules: higher base wins; same base: stable > pre-release; pre-release compared by identifiers.)
    func isNewer(_ version: String, than current: String) -> Bool {
        Self.isNewer(version, than: current)
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        let lhs = parseVersion(version)
        let rhs = parseVersion(current)

        for i in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let vi = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let ci = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if vi != ci { return vi > ci }
        }

        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(l), .some(r)):
            return comparePreRelease(l, r) == .orderedDescending
        }
    }

    func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        Self.comparePreRelease(lhs, rhs)
    }

    static func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for i in 0..<max(lhs.count, rhs.count) {
            guard i < lhs.count else { return .orderedAscending }
            guard i < rhs.count else { return .orderedDescending }

            let left = lhs[i]
            let right = rhs[i]
            if left == right { continue }

            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            }
            if Int(left) != nil { return .orderedAscending }
            if Int(right) != nil { return .orderedDescending }

            let result = left.compare(right, options: [.numeric, .caseInsensitive])
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    /// 暴露给测试：用 SHA256SUMS.txt 解析。
    /// (Test-only convenience wrapping ChecksumListing.lookup.)
    func expectedChecksum(in listing: String, assetName: String) -> String? {
        ChecksumListing.lookup(in: listing, assetName: assetName)
    }
}
