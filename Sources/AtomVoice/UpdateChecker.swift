import Cocoa

/// 轻量自动更新模块：检查 GitHub Releases，下载并替换 .app
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    private override init() {}

    private let owner = "BlackSquarre"
    private let repo  = "AtomVoice"

    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    // MARK: - 公开 API

    /// 检查更新
    /// - Parameter silent: true = 无新版时不弹提示（启动时后台静默检查用）
    func checkForUpdates(silent: Bool = false) {
        fetchLatestRelease { [weak self] result in
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
    }

    private func fetchLatestRelease(completion: @escaping (Result<Release, Error>) -> Void) {
        let urlStr = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(URLError(.badServerResponse))); return }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let assets  = json["assets"]   as? [[String: Any]]
                else { completion(.failure(URLError(.cannotParseResponse))); return }

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
                        completion(.success(Release(version: version, downloadURL: dlURL)))
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

        let alert = NSAlert()
        alert.messageText = loc("update.available.title")
        alert.informativeText = loc("update.available.message", release.version, current)
        alert.addButton(withTitle: loc("update.install"))
        alert.addButton(withTitle: loc("update.later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

                // 更新进度文字，切到后台线程解压
                self.updateProgressLabel(loc("update.installing"))
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let newApp = try self.extractZip(tmpURL)
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
        // 固定路径：进程退出后脚本还能访问
        let updateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtomVoiceUpdate")
        try? fm.removeItem(at: updateDir)
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", zipURL.path, "-d", updateDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.unzipFailed(proc.terminationStatus)
        }

        let contents = try fm.contentsOfDirectory(at: updateDir, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }
        return newApp
    }

    // MARK: - 安装与重启

    private func promptRestart(version: String, newAppURL: URL) {
        let alert = NSAlert()
        alert.messageText = loc("update.done.title")
        alert.informativeText = loc("update.done.message", version)
        alert.addButton(withTitle: loc("update.restart"))
        alert.addButton(withTitle: loc("update.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            applyAndRelaunch(newAppURL: newAppURL)
        }
    }

    /// 写一个临时 shell 脚本，等待进程退出后替换 .app 并重启
    private func applyAndRelaunch(newAppURL: URL) {
        let currentPath = Bundle.main.bundlePath
        let newPath     = newAppURL.path
        let tmpDir      = newAppURL.deletingLastPathComponent().path
        let scriptPath  = (NSTemporaryDirectory() as NSString)
                              .appendingPathComponent("atomvoice_update.sh")

        let script = """
        #!/bin/bash
        sleep 1.5
        rm -rf '\(currentPath)'
        ditto '\(newPath)' '\(currentPath)'
        open '\(currentPath)'
        rm -rf '\(tmpDir)'
        rm -f '\(scriptPath)'
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptPath)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath]
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
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 比较两个版本号字符串，如 "1.2.3" > "1.2.2"
    private func isNewer(_ version: String, than current: String) -> Bool {
        let v = version.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(v.count, c.count) {
            let vi = i < v.count ? v[i] : 0
            let ci = i < c.count ? c[i] : 0
            if vi != ci { return vi > ci }
        }
        return false
    }

    private enum UpdateError: LocalizedError {
        case unzipFailed(Int32)
        case appNotFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let code): return "unzip failed (exit code \(code))"
            case .appNotFound:           return "No .app bundle found in zip"
            }
        }
    }
}
