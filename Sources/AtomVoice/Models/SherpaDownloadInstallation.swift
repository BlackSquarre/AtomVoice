import Foundation

struct SherpaDownloadItem {
    enum Kind: String { case runtime, asr, punct }
    let kind: Kind
    let urlCandidates: [URL]
    let archiveName: String
    var runtimeRelease: SherpaRuntimeRelease? = nil
    var name: String { kind.rawValue }
}

/// 计划、解压和提交属于资源安装，不依赖下载进度或窗口。
struct SherpaDownloadInstallation {
    let paths: SherpaResourcePaths
    private let copyDirectory: (URL, URL) throws -> Void
    private let verifyRuntimeArchive: ((URL, String) throws -> Void)?
    private let validateRuntime: (SherpaRuntimeLayout) throws -> Void
    private let installPrepared: (SherpaPreparedDirectory) throws -> SherpaInstalledDirectory
    init(paths: SherpaResourcePaths = .current,
         copyDirectory: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
         verifyRuntimeArchive: ((URL, String) throws -> Void)? = nil,
         validateRuntime: @escaping (SherpaRuntimeLayout) throws -> Void = {
             guard $0.isCompatible(on: ProcessInfo.processInfo.operatingSystemVersion) else { throw SherpaRuntimeInstallError.incompatibleSystem }
         }, installPrepared: @escaping (SherpaPreparedDirectory) throws -> SherpaInstalledDirectory = { try $0.install() }) {
        self.paths = paths
        self.copyDirectory = copyDirectory
        self.verifyRuntimeArchive = verifyRuntimeArchive
        self.validateRuntime = validateRuntime
        self.installPrepared = installPrepared
    }

    func plan(preset: SherpaModelPreset, version: String, forceRuntime: Bool,
              runtimeOnly: Bool, replaceModel: Bool, runtimeRelease: SherpaRuntimeRelease? = nil) -> [SherpaDownloadItem] {
        let status = SherpaResources(paths: paths).status(for: preset)
        var items: [SherpaDownloadItem] = []
        if !status.runtimeReady || forceRuntime {
            items.append(.init(kind: .runtime,
                urlCandidates: SherpaDownloadSources.candidateURLs(for: SherpaModelDownloader.runtimeArchiveGitHubURL(for: version)),
                archiveName: "\(SherpaModelDownloader.runtimeArchiveRootName(for: version)).tar.bz2", runtimeRelease: runtimeRelease))
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
        if item.kind == .runtime {
            if let verifyRuntimeArchive { try verifyRuntimeArchive(archive, version) }
            else {
                guard let release = item.runtimeRelease, release.version == version else { throw SherpaRuntimeInstallError.releaseMetadata }
                try release.verifyArchive(archive)
            }
        }
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
            guard let layout = SherpaRuntimeLayout.resolve(in: lib) else { throw SherpaRuntimeInstallError.missingLibraries }
            try validateRuntime(layout)
            let staged = root.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: lib, to: staged.appendingPathComponent("lib", isDirectory: true))
            try version.write(to: staged.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            let preparedExtracted = try SherpaResourceInstaller.prepareDirectory(from: extracted,
                to: paths.support.appendingPathComponent(extracted.lastPathComponent, isDirectory: true), copy: copyDirectory)
            let runtime = try SherpaResourceInstaller.prepareDirectory(from: staged, to: paths.runtime.deletingLastPathComponent(), copy: copyDirectory)
            guard let installed = try attempt.commit({ () throws -> [SherpaInstalledDirectory] in
                let extractedInstall = try installPrepared(preparedExtracted)
                do {
                    let runtimeInstall = try installPrepared(runtime)
                    return [extractedInstall, runtimeInstall]
                } catch {
                    extractedInstall.rollback()
                    throw error
                }
            }) else { return false }
            installed.forEach { $0.commit() }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .sherpaResourcesDidChange, object: nil) }
            return true
        }
    }

    static func extractArchive(_ archive: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let output = try runTar(["-tjf", archive.path], in: target, listing: true)
        guard let listing = String(data: output, encoding: .utf8) else { throw SherpaRuntimeInstallError.unsafeArchive }
        let entries = listing.components(separatedBy: "\n")
        for (index, path) in entries.enumerated() {
            if path.isEmpty && index == entries.count - 1 { continue }
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."), !path.contains("\0") else {
                throw SherpaRuntimeInstallError.unsafeArchive
            }
        }
        _ = try runTar(["-xjf", archive.path, "-C", target.path], in: target, listing: false)
    }

    private static func runTar(_ arguments: [String], in directory: URL, listing: Bool) throws -> Data {
        // stderr 写入自有临时文件，避免双 Pipe 互相阻塞；诊断只保留有限长度。
        let diagnostic = directory.appendingPathComponent(".tar-stderr-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: diagnostic.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: diagnostic) }
        let errorHandle = try FileHandle(forWritingTo: diagnostic)
        defer { try? errorHandle.close() }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = listing ? pipe : FileHandle.nullDevice
        process.standardError = errorHandle
        try process.run()
        let output = listing ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? ""
            throw SherpaRuntimeInstallError.extraction("exit=\(process.terminationStatus) \(detail.prefix(2048))")
        }
        return output
    }
}

extension Notification.Name {
    static let sherpaResourcesDidChange = Notification.Name("AtomVoice.sherpaResourcesDidChange")
}
