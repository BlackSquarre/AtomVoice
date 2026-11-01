import Foundation

struct SherpaDownloadItem {
    enum Kind: String { case runtime, asr, punct }
    let kind: Kind
    let urlCandidates: [URL]
    let archiveName: String
    var name: String { kind.rawValue }
}

/// 计划、解压和提交属于资源安装，不依赖下载进度或窗口。
struct SherpaDownloadInstallation {
    let paths: SherpaResourcePaths
    private let copyDirectory: (URL, URL) throws -> Void
    init(paths: SherpaResourcePaths = .current,
         copyDirectory: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.paths = paths
        self.copyDirectory = copyDirectory
    }

    func plan(preset: SherpaModelPreset, version: String, forceRuntime: Bool,
              runtimeOnly: Bool, replaceModel: Bool) -> [SherpaDownloadItem] {
        let status = SherpaResources(paths: paths).status(for: preset)
        var items: [SherpaDownloadItem] = []
        if !status.runtimeReady || forceRuntime {
            items.append(.init(kind: .runtime,
                urlCandidates: SherpaDownloadSources.candidateURLs(for: SherpaModelDownloader.runtimeArchiveGitHubURL(for: version)),
                archiveName: "\(SherpaModelDownloader.runtimeArchiveRootName(for: version)).tar.bz2"))
        }
        if !runtimeOnly, (!status.modelReady || replaceModel), let archive = preset.archiveName, !preset.downloadURLs.isEmpty {
            items.append(.init(kind: .asr, urlCandidates: preset.downloadURLs, archiveName: archive))
        }
        if !runtimeOnly, !status.punctuationReady {
            let archive = SherpaResourcePaths.punctuationName + ".tar.bz2"
            let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/" + archive)!
            items.append(.init(kind: .punct, urlCandidates: SherpaDownloadSources.candidateURLs(for: url), archiveName: archive))
        }
        return items
    }

    func install(archive: URL, item: SherpaDownloadItem, preset: SherpaModelPreset,
                 version: String, attempt: SherpaInstallAttempt) throws -> Bool {
        let root = attempt.workingDirectory.appendingPathComponent("Extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.extractArchive(archive, to: root)
        switch item.kind {
        case .asr:
            guard let manifest = ModelManifest.discover(in: root) else { throw CocoaError(.fileReadCorruptFile) }
            try manifest.save(to: root)
            let prepared = try SherpaResourceInstaller.prepareDirectory(from: root, to: paths.model(preset), copy: copyDirectory)
            guard let installed = try attempt.commit({ try prepared.install() }) else { return false }
            installed.commit()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .sherpaResourcesDidChange, object: preset.id) }
            return true
        case .punct:
            let source = root.appendingPathComponent(SherpaResourcePaths.punctuationName, isDirectory: true)
            let prepared = try SherpaResourceInstaller.prepareDirectory(from: source, to: paths.punctuation, copy: copyDirectory)
            guard let installed = try attempt.commit({ try prepared.install() }) else { return false }
            installed.commit()
            return true
        case .runtime:
            let extracted = root.appendingPathComponent(SherpaModelDownloader.runtimeArchiveRootName(for: version), isDirectory: true)
            let lib = extracted.appendingPathComponent("lib", isDirectory: true)
            // 沿用两项既有必需库校验；准备完整后才替换正式 runtime。
            guard SherpaResourcePaths.runtimeLibraries.allSatisfy({ SherpaResources.isUsableFile(lib.appendingPathComponent($0)) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let staged = root.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: lib, to: staged.appendingPathComponent("lib", isDirectory: true))
            try version.write(to: staged.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            let preparedExtracted = try SherpaResourceInstaller.prepareDirectory(from: extracted,
                to: paths.support.appendingPathComponent(extracted.lastPathComponent, isDirectory: true), copy: copyDirectory)
            let runtime = try SherpaResourceInstaller.prepareDirectory(from: staged, to: paths.runtime.deletingLastPathComponent(), copy: copyDirectory)
            guard let installed = try attempt.commit({ () throws -> [SherpaInstalledDirectory] in
                let extractedInstall = try preparedExtracted.install()
                let runtimeInstall = try runtime.install()
                return [extractedInstall, runtimeInstall]
            }) else { return false }
            installed.forEach { $0.commit() }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .sherpaResourcesDidChange, object: nil) }
            return true
        }
    }

    static func extractArchive(_ archive: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tjf", archive.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let listing = String(data: output, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let entries = listing.components(separatedBy: "\n")
        for (index, path) in entries.enumerated() {
            if path.isEmpty && index == entries.count - 1 { continue }
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."), !path.contains("\0") else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extract.arguments = ["-xjf", archive.path, "-C", target.path]
        extract.standardOutput = FileHandle.nullDevice
        extract.standardError = FileHandle.nullDevice
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

extension Notification.Name {
    static let sherpaResourcesDidChange = Notification.Name("AtomVoice.sherpaResourcesDidChange")
}
