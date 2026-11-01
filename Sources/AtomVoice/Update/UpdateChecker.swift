import Foundation

/// 更新状态与阶段资源 owner；网络、安装及 AppKit 呈现分别委托。
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let bundleIdentifier = "com.blacksquarre.AtomVoice"
    // 本次手动迁移后的更新包只信任当前团队；保留完整的 Apple 签名链和 bundle ID 校验。
    private static let teamIdentifier = "DD4V6SJ9XL"
    private let releaseSource: ReleaseSource
    private let installer: UpdateInstaller

    private convenience init() {
        let installer = BundleUpdateInstaller(
            expectedBundleIdentifier: Self.bundleIdentifier,
            expectedTeamIdentifier: Self.teamIdentifier,
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

    private let presenter: UpdatePresenting
    private let currentVersion: () -> String
    private let currentBundlePath: () -> String

    init(releaseSource: ReleaseSource, installer: UpdateInstaller,
         presenter: UpdatePresenting = AppKitUpdatePresenter(),
         currentVersion: @escaping () -> String = { AppBundleInfo.shortVersion },
         currentBundlePath: @escaping () -> String = { Bundle.main.bundlePath }) {
        self.releaseSource = releaseSource
        self.installer = installer
        self.presenter = presenter
        self.currentVersion = currentVersion
        self.currentBundlePath = currentBundlePath
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case prompting
        case downloading
        case readyToRestart
        case applying
    }
    private(set) var state: UpdateState = .idle
    private var pendingUserVisibleCheck = false
    private struct PendingInstallation {
        let release: ReleaseInfo
        let application: OwnedUpdateArtifact
        var promptWhenAvailable: Bool
    }
    private var pendingInstallation: PendingInstallation?
    var shouldDeferRestartPrompt: (() -> Bool)?

    // MARK: - 检查与下载

    func checkForUpdates(silent: Bool = false) {
        // 用户主动稍后后保持安静；手动检查仍拉取最新 release，不能锁定旧版本。
        if state == .readyToRestart, silent { return }
        guard state == .idle || state == .readyToRestart else {
            if state == .checking, !silent { pendingUserVisibleCheck = true }
            if !silent { presenter.bringProgressToFront() }
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
                let visible = self.pendingUserVisibleCheck
                self.pendingUserVisibleCheck = false
                switch result {
                case .failure(let error):
                    self.state = self.restingState
                    if visible {
                        self.presenter.showAlert(title: loc("update.error.title"),
                            message: loc("update.error.fetch", error.localizedDescription))
                    }
                case .success(let release): self.handleRelease(release, silent: !visible)
                }
            }
        }
    }

    private func handleRelease(_ release: ReleaseInfo, silent: Bool) {
        let current = currentVersion()
        guard Self.isNewer(release.version, than: current) else {
            state = restingState
            if !silent {
                presenter.showAlert(title: loc("update.upToDate.title"), message: loc("update.upToDate.message", current))
            }
            return
        }
        if pendingInstallation?.release == release {
            state = .readyToRestart
            showRestartPrompt()
            return
        }
        state = .prompting
        guard presenter.confirmDownload(version: release.version, currentVersion: current,
            isPreRelease: release.isPreRelease, isDebugBuild: release.isDebugBuild) else {
            state = restingState
            return
        }
        startDownload(release)
    }

    private func startDownload(_ release: ReleaseInfo) {
        guard state == .prompting else { return }
        state = .downloading
        presenter.showProgress(loc("update.downloading", release.version))
        releaseSource.downloadAsset(release) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state == .downloading else { return }
                switch result {
                case .failure(let error): self.failDownload(error)
                case .success(let archive):
                    self.presenter.updateProgressLabel(loc("update.verifying"))
                    self.verifyAndInstall(archive: archive, release: release)
                }
            }
        }
    }

    private func failDownload(_ error: Error) {
        presenter.closeProgress()
        state = restingState
        presenter.showAlert(title: loc("update.error.title"), message: loc("update.error.download", error.localizedDescription))
    }

    private func verifyAndInstall(archive: OwnedUpdateArtifact, release: ReleaseInfo) {
        releaseSource.fetchChecksumsListing(for: release) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.failInstallation("Failed to fetch SHA256SUMS.txt: \(error.localizedDescription)")
                }
            case .success(let listing):
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.installer.verifyChecksum(zipURL: archive.url, listing: listing, assetName: release.assetName)
                        DispatchQueue.main.async { self.presenter.updateProgressLabel(loc("update.installing")) }
                        let application = try self.installer.extractZip(archive.url)
                        try self.installer.validateDownloadedApp(application.url, currentVersion: self.currentVersion(), expectedVersion: release.version)
                        DispatchQueue.main.async {
                            guard self.state == .downloading else { return }
                            self.presenter.closeProgress()
                            self.pendingInstallation = .init(release: release, application: application, promptWhenAvailable: true)
                            self.state = .readyToRestart
                            self.resumeDeferredRestartPromptIfPossible()
                        }
                    } catch {
                        DispatchQueue.main.async { self.failInstallation(error.localizedDescription) }
                    }
                }
            }
        }
    }

    private func failInstallation(_ message: String) {
        guard state == .downloading else { return }
        presenter.closeProgress()
        state = restingState
        presenter.showAlert(title: loc("update.error.title"), message: loc("update.error.install", message))
    }

    // MARK: - 待安装文件与进程交接

    private var restingState: UpdateState { pendingInstallation == nil ? .idle : .readyToRestart }

    func resumeDeferredRestartPromptIfPossible() {
        guard state == .readyToRestart, pendingInstallation?.promptWhenAvailable == true,
              shouldDeferRestartPrompt?() != true else { return }
        showRestartPrompt()
    }

    private func showRestartPrompt() {
        guard state == .readyToRestart, var pending = pendingInstallation else { return }
        if shouldDeferRestartPrompt?() == true {
            pending.promptWhenAvailable = true
            pendingInstallation = pending
            return
        }
        pending.promptWhenAvailable = false
        pendingInstallation = pending
        // 与下载确认一样，modal 期间不重入检查或再次呈现。
        state = .prompting
        let restartNow = presenter.confirmRestart(version: pending.release.version)
        state = .readyToRestart
        if restartNow { applyAndRelaunch(pending.application) }
    }

    private func applyAndRelaunch(_ application: OwnedUpdateArtifact) {
        guard state == .readyToRestart else { return }
        state = .applying
        do {
            try installer.applyAndRelaunch(newAppURL: application.url, currentBundlePath: currentBundlePath())
            application.handOffToInstaller()
            pendingInstallation = nil
            presenter.terminateApplication()
        } catch {
            // 脚本尚未接管：保留资源供用户稍后手动重试。
            state = .readyToRestart
            presenter.showAlert(title: loc("update.error.title"), message: loc("update.error.install", error.localizedDescription))
        }
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
