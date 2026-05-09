import Cocoa

/// 手动导入 Sherpa 模型包流程（Manual Sherpa model import flow）
/// 支持 .tar.bz2 / .tar.gz / .tgz / .zip / 已解压目录
/// (Supports .tar.bz2 / .tar.gz / .tgz / .zip archives, or already-extracted directory)
final class SherpaModelImportFlow {
    /// 完成回调（main thread）；nil 表示用户取消或失败
    /// (Completion callback on main thread; nil = cancelled or failed)
    typealias Completion = (SherpaImportedPresetRecord?) -> Void

    private weak var parentWindow: NSWindow?

    init(parentWindow: NSWindow?) {
        self.parentWindow = parentWindow
    }

    func run(completion: @escaping Completion) {
        let panel = NSOpenPanel()
        panel.title = loc("sherpa.import.pickerTitle")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []  // 用 fileExtensions 兼容更多压缩格式（use ext check for more formats）

        let runPick: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { completion(nil); return }
            guard response == .OK, let url = panel.url else { completion(nil); return }
            self.handlePicked(url: url, completion: completion)
        }

        if let parentWindow {
            panel.beginSheetModal(for: parentWindow, completionHandler: runPick)
        } else {
            runPick(panel.runModal())
        }
    }

    // MARK: - 处理选择（Handle picked URL）

    private func handlePicked(url: URL, completion: @escaping Completion) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: Result<URL, ImportError>
            if isDirectory {
                result = self.copyDirectoryIntoModels(source: url)
            } else {
                result = self.extractArchiveIntoModels(archive: url)
            }

            switch result {
            case .failure(let err):
                DispatchQueue.main.async {
                    self.showError(err)
                    completion(nil)
                }
            case .success(let modelDir):
                guard let manifest = ModelManifest.discover(in: modelDir) else {
                    DispatchQueue.main.async {
                        self.showError(.unrecognizedContents(modelDir.lastPathComponent))
                        // 失败的临时目录不清理，留给用户排查（Don't auto-clean failed dir; leave for user inspection）
                        completion(nil)
                    }
                    return
                }
                try? manifest.save(to: modelDir)

                let sizeMB = self.directorySizeMB(modelDir)
                DispatchQueue.main.async {
                    self.askLanguage(for: modelDir, sizeMB: sizeMB) { language in
                        guard let language else { completion(nil); return }
                        let id = self.uniqueImportID(from: modelDir.lastPathComponent)
                        let record = SherpaImportedPresetRecord(
                            id: id,
                            language: language,
                            extractedDirName: modelDir.lastPathComponent,
                            sizeMB: sizeMB,
                            importedAt: Date()
                        )
                        SherpaImportedPresetStore.shared.add(record)
                        completion(record)
                    }
                }
            }
        }
    }

    // MARK: - 拷贝/解压（Copy / extract）

    /// 把已解压的目录复制到 models/。如果用户选的目录本身不是模型根（缺少 .onnx），尝试找子目录
    /// (Copy already-extracted directory to models/. If picked dir itself isn't a model root, try sub-directory)
    private func copyDirectoryIntoModels(source: URL) -> Result<URL, ImportError> {
        // 先看 source 自身是否是模型目录
        let directRoot = locateModelRoot(in: source)
        guard let modelRoot = directRoot else {
            return .failure(.unrecognizedContents(source.lastPathComponent))
        }

        let modelsDir = SherpaOnnxRecognizerController.modelsDirectory
        try? SherpaOnnxRecognizerController.createSupportDirectories()
        let target = modelsDir.appendingPathComponent(modelRoot.lastPathComponent, isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: modelRoot, to: target)
            return .success(target)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
    }

    private func extractArchiveIntoModels(archive: URL) -> Result<URL, ImportError> {
        let ext = archive.pathExtension.lowercased()
        let lower = archive.lastPathComponent.lowercased()
        let tarFlag: String?
        if lower.hasSuffix(".tar.bz2") || ext == "bz2" { tarFlag = "-xjf" }
        else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || ext == "gz" || ext == "tgz" { tarFlag = "-xzf" }
        else if ext == "tar" { tarFlag = "-xf" }
        else if ext == "zip" { tarFlag = nil }
        else { return .failure(.unsupportedArchive(archive.lastPathComponent)) }

        // 解压到一个临时目录，再把里面的模型根挪进 models/
        // (Extract to temp dir first, then move the model root into models/)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoiceSherpaImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        let process = Process()
        if let flag = tarFlag {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [flag, archive.path, "-C", temp.path]
        } else {
            // .zip
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", temp.path]
        }
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return .failure(.extractFailed("解压器退出码 \(process.terminationStatus)"))
            }
        } catch {
            return .failure(.extractFailed(error.localizedDescription))
        }

        // 在 temp 中找模型根目录
        guard let root = locateModelRoot(in: temp) else {
            return .failure(.unrecognizedContents(archive.lastPathComponent))
        }

        let modelsDir = SherpaOnnxRecognizerController.modelsDirectory
        try? SherpaOnnxRecognizerController.createSupportDirectories()
        let target = modelsDir.appendingPathComponent(root.lastPathComponent, isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            // 跨卷可能 fail，先尝试 move，失败 fallback copy
            // (cross-volume move may fail; try move first, fallback to copy)
            do {
                try FileManager.default.moveItem(at: root, to: target)
            } catch {
                try FileManager.default.copyItem(at: root, to: target)
            }
            return .success(target)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
    }

    /// 在给定目录下找模型根：
    /// 1. 自身就是（含 .onnx 文件）→ 返回自身
    /// 2. 唯一子目录是 → 返回子目录
    /// 3. 任意子目录的 ModelManifest.discover 成功 → 返回该子目录
    /// (Find model root: itself if it has .onnx files; else single subdir; else first subdir that discovers)
    private func locateModelRoot(in directory: URL) -> URL? {
        let fm = FileManager.default

        if ModelManifest.discover(in: directory) != nil { return directory }

        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        let subdirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if subdirs.count == 1, ModelManifest.discover(in: subdirs[0]) != nil {
            return subdirs[0]
        }
        return subdirs.first { ModelManifest.discover(in: $0) != nil }
    }

    // MARK: - 收尾（Finalization）

    private func askLanguage(for modelDir: URL, sizeMB: Int, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.import.languageTitle")

        // 优先使用从目录名识别到的语言；识别不到则回退到用户当前的识别语言
        // (Prefer language inferred from directory name; fall back to current recognition language)
        let detectedLang = Self.detectLanguage(fromDirName: modelDir.lastPathComponent)
        let fallbackLang = AppSettings.sherpaRecognitionLanguage
        let presetLang = detectedLang ?? fallbackLang

        var info = loc("sherpa.import.languageMessage", modelDir.lastPathComponent, sizeMB)
        if let detected = detectedLang {
            info += "\n" + loc("sherpa.import.detected", AppSettings.displayName(forRecognitionLanguage: detected))
        }
        alert.informativeText = info

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24), pullsDown: false)
        for code in SherpaModelPreset.supportedRecognitionLanguages {
            let item = NSMenuItem(title: AppSettings.displayName(forRecognitionLanguage: code), action: nil, keyEquivalent: "")
            item.representedObject = code
            popup.menu?.addItem(item)
        }
        if let item = popup.menu?.items.first(where: { ($0.representedObject as? String) == presetLang }) {
            popup.select(item)
        }
        alert.accessoryView = popup

        alert.addButton(withTitle: loc("sherpa.import.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))

        let response = AppDelegate.runModalAlert(alert)
        guard response == .alertFirstButtonReturn,
              let lang = popup.selectedItem?.representedObject as? String else {
            completion(nil)
            return
        }
        completion(lang)
    }

    private func uniqueImportID(from baseName: String) -> String {
        // 用目录名做 ID 的基础；与已有内置/导入 preset 撞名时加后缀
        // (Use directory name as ID base; suffix on collision)
        let existing = Set(SherpaModelPreset.allPresets.map { $0.id })
        if !existing.contains(baseName) { return baseName }
        for i in 2...99 {
            let candidate = "\(baseName)#\(i)"
            if !existing.contains(candidate) { return candidate }
        }
        return baseName + "#" + UUID().uuidString.prefix(8)
    }

    private func directorySizeMB(_ directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return Int(total / (1024 * 1024))
    }

    /// 从目录名推断模型语言（Infer model language from directory name）
    /// Sherpa 命名约定较稳定：含 "bilingual"、"-zh-"/"chinese"、"-en-"/"english"、"-ja-"/"japanese"、
    /// "korean"/"-ko-"、"-fr-"/"french"、"-de-"/"german"、"-es-"/"spanish"
    /// (Sherpa naming is fairly consistent across releases)
    static func detectLanguage(fromDirName name: String) -> String? {
        let lower = "-" + name.lowercased() + "-"
        if lower.contains("bilingual") { return "bilingual" }
        if lower.contains("-zh-tw-") || lower.contains("traditional") || lower.contains("cantonese") { return "zh-TW" }
        if lower.contains("-zh-") || lower.contains("chinese") || lower.contains("mandarin") { return "zh-CN" }
        if lower.contains("japanese") || lower.contains("-ja-") || lower.contains("-jp-") { return "ja-JP" }
        if lower.contains("korean") || lower.contains("-ko-") || lower.contains("-kr-") { return "ko-KR" }
        if lower.contains("french") || lower.contains("-fr-") { return "fr-FR" }
        if lower.contains("german") || lower.contains("-de-") { return "de-DE" }
        if lower.contains("spanish") || lower.contains("-es-") { return "es-ES" }
        if lower.contains("-en-") || lower.contains("english") { return "en-US" }
        return nil
    }

    private func showError(_ error: ImportError) {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.import.failedTitle")
        alert.informativeText = error.userMessage
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("common.ok"))
        _ = AppDelegate.runModalAlert(alert)
    }
}

private extension SherpaModelImportFlow {
    enum ImportError: Error {
        case unsupportedArchive(String)
        case extractFailed(String)
        case copyFailed(String)
        case unrecognizedContents(String)

        var userMessage: String {
            switch self {
            case .unsupportedArchive(let name):
                return loc("sherpa.import.error.unsupported", name)
            case .extractFailed(let detail):
                return loc("sherpa.import.error.extract", detail)
            case .copyFailed(let detail):
                return loc("sherpa.import.error.copy", detail)
            case .unrecognizedContents(let name):
                return loc("sherpa.import.error.unrecognized", name)
            }
        }
    }
}
