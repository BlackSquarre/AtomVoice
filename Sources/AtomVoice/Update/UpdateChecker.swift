import Cocoa
import CryptoKit
import Security

/// 轻量自动更新模块：检查 GitHub Releases，下载并替换 .app（Lightweight auto-update module: check GitHub Releases, download and replace .app）
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    private override init() {}

    private let owner = "BlackSquarre"
    private let repo  = "AtomVoice"
    private let expectedBundleIdentifier = "com.blacksquarre.AtomVoice"
    private let expectedTeamIdentifier = "NC623693G3"

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
    /// - Parameter silent: true = 无新版时不弹提示，启动时后台静默检查用（true = no alert when up-to-date, for silent background check on launch）
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
        fetchLatestRelease(includeBeta: includeBeta, preferDebugBuild: preferDebugBuild) { [weak self] result in
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

    // MARK: - 获取最新 Release

    private struct Release {
        let version: String
        let downloadURL: URL
        let assetName: String
        let checksumsURL: URL
        let isPreRelease: Bool
        let isDebugBuild: Bool
    }

    private func fetchLatestRelease(includeBeta: Bool, preferDebugBuild: Bool, completion: @escaping (Result<Release, Error>) -> Void) {
        // includeBeta 时拉取列表取第一条（含 pre-release），否则只取正式最新版
        // (When includeBeta is true, fetch the list and take the first entry including pre-release; otherwise fetch only the latest stable release)
        let urlStr = includeBeta
            ? "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=1"
            : "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(URLError(.badServerResponse))); return }
            do {
                // 列表端点返回数组，latest 端点返回对象（List endpoint returns array, latest endpoint returns object）
                let jsonObject = try JSONSerialization.jsonObject(with: data)
                let json: [String: Any]?
                if let arr = jsonObject as? [[String: Any]] {
                    json = arr.first
                } else {
                    json = jsonObject as? [String: Any]
                }
                guard let json,
                      let tagName   = json["tag_name"]   as? String,
                      let assets    = json["assets"]     as? [[String: Any]]
                else { completion(.failure(URLError(.cannotParseResponse))); return }

                let isPreRelease = json["prerelease"] as? Bool ?? false
                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                // 按当前更新通道匹配资产：普通通道排除 Debug 包；Debug 通道只取 Debug Universal。
                // (Match by update channel: normal channel excludes Debug assets; Debug channel only takes Debug Universal.)
                let preferred: [String]
                if preferDebugBuild {
                    preferred = ["Debug-Universal", "DebugUniversal", "Debug"]
                } else {
                    #if arch(arm64)
                    preferred = ["AppleSilicon", "Universal"]
                    #else
                    preferred = ["Intel", "Universal"]
                    #endif
                }

                // 校验文件 SHA256SUMS.txt 与 release 一起发布
                // (Checksum file SHA256SUMS.txt is published with each release.)
                guard let checksumsAsset = assets.first(where: { ($0["name"] as? String) == "SHA256SUMS.txt" }),
                      let checksumsURLStr = checksumsAsset["browser_download_url"] as? String,
                      let checksumsURL = URL(string: checksumsURLStr) else {
                    completion(.failure(URLError(.fileDoesNotExist)))
                    return
                }

                for suffix in preferred {
                    if let asset = assets.first(where: {
                           guard let name = $0["name"] as? String else { return false }
                           guard name.contains(suffix), name.hasSuffix(".zip") else { return false }
                           let isDebugAsset = name.localizedCaseInsensitiveContains("debug")
                           return preferDebugBuild ? isDebugAsset : !isDebugAsset
                       }),
                       let assetName = asset["name"] as? String,
                       let dlStr = asset["browser_download_url"] as? String,
                       let dlURL = URL(string: dlStr) {
                        completion(.success(Release(version: version,
                                                    downloadURL: dlURL,
                                                    assetName: assetName,
                                                    checksumsURL: checksumsURL,
                                                    isPreRelease: isPreRelease,
                                                    isDebugBuild: preferDebugBuild)))
                        return
                    }
                }
                completion(.failure(URLError(.fileDoesNotExist)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - 版本比对与提示

    private func handleRelease(_ release: Release, silent: Bool) {
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

    private func startDownload(_ release: Release) {
        guard state == .prompting else { return }
        state = .downloading
        showProgress(loc("update.downloading", release.version))

        URLSession.shared.downloadTask(with: release.downloadURL) { [weak self] tmpURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.closeProgress()
                    self.state = .idle
                    self.showAlert(title: loc("update.error.title"),
                                   message: loc("update.error.download", error.localizedDescription))
                    return
                }
                guard let tmpURL else {
                    self.closeProgress()
                    self.state = .idle
                    self.showAlert(title: loc("update.error.title"),
                                   message: loc("update.error.download", URLError(.badServerResponse).localizedDescription))
                    return
                }

                self.updateProgressLabel(loc("update.verifying"))
                self.verifyChecksum(zipURL: tmpURL, release: release) { result in
                    switch result {
                    case let .failure(error):
                        DispatchQueue.main.async {
                            self.closeProgress()
                            self.state = .idle
                            self.showAlert(title: loc("update.error.title"),
                                           message: loc("update.error.install", error.localizedDescription))
                        }
                    case .success:
                        self.installVerifiedUpdate(zipURL: tmpURL, release: release)
                    }
                }
            }
        }.resume()
    }

    private func installVerifiedUpdate(zipURL: URL, release: Release) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                DispatchQueue.main.async { self.updateProgressLabel(loc("update.installing")) }
                let newApp = try self.extractZip(zipURL)
                try self.validateDownloadedApp(newApp, expectedVersion: release.version)
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

    // MARK: - 校验 SHA256

    /// 下载 SHA256SUMS.txt，根据资产名查 hash 并与下载到本地的 zip 文件比对。
    /// (Download SHA256SUMS.txt, look up the hash by asset name, and compare against the downloaded zip.)
    private func verifyChecksum(zipURL: URL, release: Release, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = URLRequest(url: release.checksumsURL, timeoutInterval: 15)
        req.setValue("text/plain", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error {
                completion(.failure(UpdateError.checksumFetchFailed(error.localizedDescription)))
                return
            }
            guard let self,
                  let data,
                  let listing = String(data: data, encoding: .utf8) else {
                completion(.failure(UpdateError.checksumFetchFailed("empty response")))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.verifyChecksum(zipURL: zipURL, listing: listing, assetName: release.assetName)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    private func verifyChecksum(zipURL: URL, listing: String, assetName: String) throws {
        guard let expectedHash = expectedChecksum(in: listing, assetName: assetName) else {
            throw UpdateError.checksumMissing(assetName)
        }

        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = fileHandle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard actualHash == expectedHash else {
            throw UpdateError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }
    }

    func expectedChecksum(in listing: String, assetName: String) -> String? {
        // 每行格式：<sha256>  <filename>（shasum -a 256 输出格式）
        // (Each line: "<sha256>  <filename>" — output format of `shasum -a 256`.)
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == assetName {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }

    // MARK: - 解压

    private func extractZip(_ zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let updateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtomVoiceUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)

        try validateZipEntries(zipURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", zipURL.path, "-d", updateDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.unzipFailed(proc.terminationStatus)
        }

        let contents = try fm.contentsOfDirectory(at: updateDir, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first else {
            throw UpdateError.appNotFound
        }
        return newApp
    }

    private func validateZipEntries(_ zipURL: URL) throws {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", zipURL.path]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.zipListingFailed(proc.terminationStatus)
        }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let listing = String(data: output, encoding: .utf8) else {
            throw UpdateError.invalidZipEntry("<invalid utf8>")
        }

        for entry in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(entry)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.hasPrefix("/") || components.contains("..") || path.contains("\0") {
                throw UpdateError.invalidZipEntry(path)
            }
        }
    }

    private func validateDownloadedApp(_ appURL: URL, expectedVersion: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw UpdateError.invalidBundle("Cannot read Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier else {
            throw UpdateError.invalidBundle("Unexpected bundle identifier")
        }

        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let downloadedVersion = info["CFBundleShortVersionString"] as? String,
              isNewer(downloadedVersion, than: current) || downloadedVersion == expectedVersion else {
            throw UpdateError.invalidBundle("Downloaded app version is not newer")
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw UpdateError.signatureInvalid(securityErrorDescription(createStatus))
        }

        let requirementText = """
        anchor apple generic and identifier "\(expectedBundleIdentifier)" and certificate leaf[subject.OU] = "\(expectedTeamIdentifier)"
        """
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw UpdateError.signatureInvalid(securityErrorDescription(requirementStatus))
        }

        var validationError: Unmanaged<CFError>?
        let validateStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement,
            &validationError
        )
        if validateStatus != errSecSuccess {
            let detail = validationError?.takeRetainedValue().localizedDescription
            throw UpdateError.signatureInvalid(securityErrorDescription(validateStatus, detail: detail))
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let dict = signingInfo as? [String: Any],
              dict[kSecCodeInfoIdentifier as String] as? String == expectedBundleIdentifier,
              dict[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamIdentifier else {
            throw UpdateError.signatureInvalid(securityErrorDescription(infoStatus))
        }
    }

    private func securityErrorDescription(_ status: OSStatus, detail: String? = nil) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        if let detail, !detail.isEmpty {
            return "\(message): \(detail)"
        }
        return message
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

        // 强提醒：抢占前台 + Dock 跳动直到用户响应
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

    /// 写一个临时 shell 脚本，等待进程退出后替换 .app 并重启（Write a temporary shell script that waits for process exit, replaces .app, and relaunches）
    private func applyAndRelaunch(newAppURL: URL) {
        guard state == .readyToRestart else { return }
        state = .applying
        let currentPath = Bundle.main.bundlePath
        let newPath     = newAppURL.path
        let tmpDir      = newAppURL.deletingLastPathComponent().path
        let scriptPath  = (NSTemporaryDirectory() as NSString)
                              .appendingPathComponent("atomvoice_update_\(UUID().uuidString).sh")

        let script = """
        #!/bin/bash
        set -euo pipefail
        current_path="$1"
        new_path="$2"
        tmp_dir="$3"
        backup_path="${current_path}.previous"

        sleep 1.5
        rm -rf -- "$backup_path"
        if [ -e "$current_path" ]; then
          mv -- "$current_path" "$backup_path"
        fi
        if ditto -- "$new_path" "$current_path"; then
          open -- "$current_path"
          rm -rf -- "$backup_path"
          rm -rf -- "$tmp_dir"
          rm -f -- "$0"
        else
          rm -rf -- "$current_path"
          if [ -e "$backup_path" ]; then
            mv -- "$backup_path" "$current_path"
          fi
          rm -rf -- "$tmp_dir"
          rm -f -- "$0"
          exit 1
        fi
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptPath)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, currentPath, newPath, tmpDir]
            try proc.run()
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
    /// (Parse version string, compatible with GitHub tag format "0.10.1-Beta-2" and Info.plist format "0.10.1 Beta 2".)
    func parseVersion(_ version: String) -> ParsedVersion {
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

    /// 比较两个版本号（支持 pre-release 格式，如 0.9.5-beta.1 / 0.9.5 Beta 1）
    /// 规则：基础版本号更大 → 更新；基础相同时 stable > pre-release；pre-release 按标识符比较。
    /// (Compare two version numbers (supports pre-release formats like 0.9.5-beta.1 / 0.9.5 Beta 1).
    /// Rules: higher base version → newer; same base: stable > pre-release; pre-release compared by identifiers.)
    func isNewer(_ version: String, than current: String) -> Bool {
        let version = parseVersion(version)
        let current = parseVersion(current)

        for i in 0..<max(version.numbers.count, current.numbers.count) {
            let vi = i < version.numbers.count ? version.numbers[i] : 0
            let ci = i < current.numbers.count ? current.numbers[i] : 0
            if vi != ci { return vi > ci }
        }

        switch (version.preRelease, current.preRelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhs), .some(rhs)):
            return comparePreRelease(lhs, rhs) == .orderedDescending
        }
    }

    func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
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

    private enum UpdateError: LocalizedError {
        case unzipFailed(Int32)
        case appNotFound
        case zipListingFailed(Int32)
        case invalidZipEntry(String)
        case invalidBundle(String)
        case signatureInvalid(String)
        case checksumFetchFailed(String)
        case checksumMissing(String)
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let code): return "unzip failed (exit code \(code))"
            case .appNotFound:           return "No .app bundle found in zip"
            case .zipListingFailed(let code):
                return "zip listing failed (exit code \(code))"
            case .invalidZipEntry(let entry):
                return "Unsafe zip entry: \(entry)"
            case .invalidBundle(let reason):
                return "Downloaded app is invalid: \(reason)"
            case .signatureInvalid(let reason):
                return "Downloaded app signature is invalid: \(reason)"
            case .checksumFetchFailed(let reason):
                return "Failed to fetch SHA256SUMS.txt: \(reason)"
            case .checksumMissing(let asset):
                return "SHA256 entry missing for \(asset)"
            case .checksumMismatch(let expected, let actual):
                return "SHA256 mismatch (expected \(expected), got \(actual))"
            }
        }
    }
}
