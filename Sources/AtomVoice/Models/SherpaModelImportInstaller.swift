import Foundation

/// 导入期间只拥有暂存副本，语言确认后才安装；失败时恢复旧目录。
final class SherpaPreparedImport {
    let directory: URL
    let targetName: String
    let sizeMB: Int
    private let workingDirectory: URL
    init(directory: URL, targetName: String, sizeMB: Int, workingDirectory: URL) {
        self.directory = directory
        self.targetName = targetName
        self.sizeMB = sizeMB
        self.workingDirectory = workingDirectory
    }
    deinit {
        let directory = workingDirectory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }
}

final class SherpaModelImportInstaller {
    private let paths: SherpaResourcePaths
    init(paths: SherpaResourcePaths = .current) { self.paths = paths }

    func prepare(_ url: URL) -> Result<SherpaPreparedImport, SherpaImportError> {
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoiceSherpaImport-\(UUID().uuidString)", isDirectory: true)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let result = isDirectory ? stageDirectory(source: url, workingDirectory: workingDirectory) : stageArchive(archive: url, workingDirectory: workingDirectory)
        switch result {
        case .failure(let error):
            try? FileManager.default.removeItem(at: workingDirectory)
            return .failure(error)
        case .success(let directory):
            guard let manifest = ModelManifest.discover(in: directory) else {
                try? FileManager.default.removeItem(at: workingDirectory)
                return .failure(.unrecognizedContents(url.lastPathComponent))
            }
            do { try manifest.save(to: directory) }
            catch {
                try? FileManager.default.removeItem(at: workingDirectory)
                return .failure(.copyFailed(error.localizedDescription))
            }
            return .success(.init(directory: directory, targetName: directory.lastPathComponent,
                sizeMB: directorySizeMB(directory), workingDirectory: workingDirectory))
        }
    }

    func install(_ prepared: SherpaPreparedImport, record: SherpaImportedPresetRecord,
                 store: SherpaImportedPresetStore = .shared) -> Result<URL, SherpaImportError> {
        do {
            let target = paths.models.appendingPathComponent(record.extractedDirName, isDirectory: true)
            let installed = try SherpaResourceInstaller.replaceDirectory(from: prepared.directory, to: target)
            guard store.add(record) else {
                installed.rollback()
                return .failure(.copyFailed(CocoaError(.fileWriteUnknown).localizedDescription))
            }
            installed.commit()
            return .success(target)
        } catch { return .failure(.copyFailed(error.localizedDescription)) }
    }

    // MARK: - 拷贝/解压（Copy / extract）

    /// 把已解压的目录复制到 models/。如果用户选的目录本身不是模型根（缺少 .onnx），尝试找子目录
    /// (Copy already-extracted directory to models/. If picked dir itself isn't a model root, try sub-directory)
    private func stageDirectory(source: URL, workingDirectory: URL) -> Result<URL, SherpaImportError> {
        // 先看 source 自身是否是模型目录
        let directRoot = locateModelRoot(in: source)
        guard let modelRoot = directRoot else {
            return .failure(.unrecognizedContents(source.lastPathComponent))
        }

        let modelsDir = workingDirectory
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
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

    private func stageArchive(archive: URL, workingDirectory: URL) -> Result<URL, SherpaImportError> {
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
                return .failure(.extractFailed(loc("sherpa.import.error.extractorExitCode", process.terminationStatus)))
            }
        } catch {
            return .failure(.extractFailed(error.localizedDescription))
        }

        // 在 temp 中找模型根目录
        guard let root = locateModelRoot(in: temp) else {
            return .failure(.unrecognizedContents(archive.lastPathComponent))
        }

        let modelsDir = workingDirectory
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
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
    func locateModelRoot(in directory: URL) -> URL? {
        let fm = FileManager.default

        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        let subdirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let hasOwnONNX = children.contains { $0.pathExtension.lowercased() == "onnx" }
        if !hasOwnONNX, subdirs.count == 1, ModelManifest.discover(in: subdirs[0]) != nil { return subdirs[0] }
        if ModelManifest.discover(in: directory) != nil { return directory }
        return subdirs.first { ModelManifest.discover(in: $0) != nil }
    }

    func directorySizeMB(_ directory: URL) -> Int {
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

}

enum SherpaImportError: Error {
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
