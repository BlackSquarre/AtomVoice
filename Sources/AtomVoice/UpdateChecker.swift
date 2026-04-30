import Cocoa
import Security

/// 轻量自动更新模块：检查 GitHub Releases，下载并替换 .app
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    private override init() {}

    private let owner = "BlackSquarre"
    private let repo  = "AtomVoice"
    private let expectedBundleIdentifier = "com.blacksquarre.AtomVoice"
    private let expectedTeamIdentifier = "NC623693G3"

    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    // MARK: - 公开 API

    /// 检查更新
    /// - Parameter silent: true = 无新版时不弹提示（启动时后台静默检查用）
    func checkForUpdates(silent: Bool = false) {
        let includeBeta = UserDefaults.standard.bool(forKey: "includeBetaUpdates")
        fetchLatestRelease(includeBeta: includeBeta) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    if !silent {
                        self?.showAlert(title: loc("update.error.title"),
                                        message: loc("update.error.fetch", err.localizedDescription))
                    }
                case .success(let release):
                    self?.handleRelease(release, silent: silent)
                }
            }
        }
    }

    // MARK: - 获取最新 Release

    private struct Release {
        let version: String
        let downloadURL: URL
        let isPreRelease: Bool
    }

    private func fetchLatestRelease(includeBeta: Bool, completion: @escaping (Result<Release, Error>) -> Void) {
        // includeBeta 时拉取列表取第一条（含 pre-release），否则只取正式最新版
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
                // 列表端点返回数组，latest 端点返回对象
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

                // 优先 Universal，其次按当前架构选包
                #if arch(arm64)
                let preferred = ["Universal", "AppleSilicon"]
                #else
                let preferred = ["Universal", "Intel"]
                #endif

                for suffix in preferred {
                    if let asset = assets.first(where: {
                           ($0["name"] as? String)?.contains(suffix) == true &&
                           ($0["name"] as? String)?.hasSuffix(".zip") == true
                       }),
                       let dlStr = asset["browser_download_url"] as? String,
                       let dlURL = URL(string: dlStr) {
                        completion(.success(Release(version: version, downloadURL: dlURL, isPreRelease: isPreRelease)))
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
            if !silent {
                showAlert(title: loc("update.upToDate.title"),
                          message: loc("update.upToDate.message", current))
            }
            return
        }

        let displayVersion = release.isPreRelease
            ? "\(release.version) (\(loc("update.beta")))"
            : release.version

        let alert = NSAlert()
        alert.messageText = loc("update.available.title")
        alert.informativeText = loc("update.available.message", displayVersion, current)
        alert.addButton(withTitle: loc("update.install"))
        alert.addButton(withTitle: loc("update.later"))
        guard AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn else { return }
        startDownload(release)
    }

    // MARK: - 下载

    private func startDownload(_ release: Release) {
        showProgress(loc("update.downloading", release.version))

        URLSession.shared.downloadTask(with: release.downloadURL) { [weak self] tmpURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.closeProgress()
                    self.showAlert(title: loc("update.error.title"),
                                  message: loc("update.error.download", error.localizedDescription))
                    return
                }
                guard let tmpURL else { return }

                self.updateProgressLabel(loc("update.installing"))
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let newApp = try self.extractZip(tmpURL)
                        try self.validateDownloadedApp(newApp, expectedVersion: release.version)
                        DispatchQueue.main.async {
                            self.closeProgress()
                            self.promptRestart(version: release.version, newAppURL: newApp)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.closeProgress()
                            self.showAlert(title: loc("update.error.title"),
                                          message: loc("update.error.install", error.localizedDescription))
                        }
                    }
                }
            }
        }.resume()
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
        let alert = NSAlert()
        alert.messageText = loc("update.done.title")
        alert.informativeText = loc("update.done.message", version)
        alert.addButton(withTitle: loc("update.restart"))
        alert.addButton(withTitle: loc("update.later"))
        if AppDelegate.runModalAlert(alert) == .alertFirstButtonReturn {
            applyAndRelaunch(newAppURL: newAppURL)
        }
    }

    /// 写一个临时 shell 脚本，等待进程退出后替换 .app 并重启
    private func applyAndRelaunch(newAppURL: URL) {
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
        AppDelegate.bringToFront(w)
    }

    private func updateProgressLabel(_ message: String) {
        progressLabel?.stringValue = message
    }

    private func closeProgress() {
        if let w = progressWindow {
            w.close()
            AppDelegate.resetActivationIfNeeded(closing: w)
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
        AppDelegate.runModalAlert(alert)
    }

    /// 将版本字符串拆分为基础版本号和 pre-release 标签
    /// 例："0.9.5-beta.1" → ("0.9.5", "beta.1")；"0.9.5" → ("0.9.5", nil)
    private func splitPreRelease(_ version: String) -> (base: String, preRelease: String?) {
        let s = version.hasPrefix("v") ? String(version.dropFirst()) : version
        if let idx = s.firstIndex(of: "-") {
            return (String(s[..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }

    /// 比较两个版本号（支持 pre-release 格式，如 0.9.5-beta.1）
    /// 规则：基础版本号更大 → 更新；基础相同时 stable > pre-release
    private func isNewer(_ version: String, than current: String) -> Bool {
        let (vBase, vPre) = splitPreRelease(version)
        let (cBase, cPre) = splitPreRelease(current)
        let v = vBase.split(separator: ".").compactMap { Int($0) }
        let c = cBase.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(v.count, c.count) {
            let vi = i < v.count ? v[i] : 0
            let ci = i < c.count ? c[i] : 0
            if vi != ci { return vi > ci }
        }
        // 基础版本号相同：stable 比 pre-release 新；pre-release 比 stable 旧
        if cPre != nil && vPre == nil { return true }
        if cPre == nil && vPre != nil { return false }
        return false
    }

    private enum UpdateError: LocalizedError {
        case unzipFailed(Int32)
        case appNotFound
        case zipListingFailed(Int32)
        case invalidZipEntry(String)
        case invalidBundle(String)
        case signatureInvalid(String)

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
            }
        }
    }
}
