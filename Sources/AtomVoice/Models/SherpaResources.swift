import Foundation

/// 资源路径不依赖识别器；保留所有既有用户目录。
struct SherpaResourcePaths {
    static let current = SherpaResourcePaths(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AtomVoice/SherpaOnnx", isDirectory: true))
    static let punctuationName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
    static let runtimeLibraries = [SherpaRuntimeLayout.sherpaLibrary, SherpaRuntimeLayout.preferredOnnxLibrary]
    let support: URL
    var runtime: URL { support.appendingPathComponent("runtime/lib", isDirectory: true) }
    var models: URL { support.appendingPathComponent("models", isDirectory: true) }
    var punctuation: URL { models.appendingPathComponent(Self.punctuationName, isDirectory: true) }
    var version: URL { support.appendingPathComponent("runtime/version.txt") }
    func model(_ preset: SherpaModelPreset) -> URL { models.appendingPathComponent(preset.extractedDirName, isDirectory: true) }
    func createDirectories() throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }
}

struct SherpaResourceStatus: Equatable {
    let runtimeReady: Bool
    let modelReady: Bool
    let punctuationReady: Bool
    var recognitionReady: Bool { runtimeReady && modelReady }
    var allReady: Bool { recognitionReady && punctuationReady }
}

struct SherpaResources {
    let paths: SherpaResourcePaths
    let operatingSystemVersion: OperatingSystemVersion
    init(paths: SherpaResourcePaths = .current,
         operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.paths = paths
        self.operatingSystemVersion = operatingSystemVersion
    }

    var runtimeReady: Bool {
        guard let layout = SherpaRuntimeLayout.resolve(in: paths.runtime) else { return false }
        return layout.isCompatible(on: operatingSystemVersion)
    }

    func status(for preset: SherpaModelPreset) -> SherpaResourceStatus {
        .init(runtimeReady: runtimeReady,
              modelReady: ModelManifest.inspect(in: paths.model(preset)) != nil,
              punctuationReady: Self.isUsableFile(paths.punctuation.appendingPathComponent("model.int8.onnx")))
    }

    /// 运行前恢复原有缓存/运行库路径；可选标点不阻断已有主识别与启发式降级。
    func ensureRecognitionReady(for preset: SherpaModelPreset) -> Bool {
        _ = ModelManifest.resolve(in: paths.model(preset))
        if !status(for: preset).runtimeReady {
            do { try repairRuntimeIfNeeded() }
            catch { DebugLog.error("[SherpaOnnx] Failed to repair runtime library path: \(error)") }
        }
        return status(for: preset).recognitionReady
    }

    static func isUsableFile(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else { return false }
        return size.int64Value > 0
    }

    /// 既有自动修复的显式入口；只补缺，不把查询变成安装。
    func repairRuntimeIfNeeded() throws {
        guard !runtimeReady else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: paths.support, includingPropertiesForKeys: nil),
              !contents.isEmpty else { return }
        let version = (try? String(contentsOf: paths.version, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = version.map { SherpaModelDownloader.runtimeArchiveRootName(for: $0) }
        // 有版本记录时只从同版缓存补缺，不能从另一版本拼凑可加载库。
        let source: URL?
        if let preferredName {
            source = contents.first { $0.lastPathComponent == preferredName }
        } else {
            guard !Self.isUsableFile(paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary)) else { return }
            source = SherpaRuntimeRelease.knownCompatible.compactMap { release in
                contents.first { $0.lastPathComponent == SherpaModelDownloader.runtimeArchiveRootName(for: release.version) }
            }.first
        }
        guard let source else { return }
        let lib = source.appendingPathComponent("lib", isDirectory: true)
        guard let layout = SherpaRuntimeLayout.resolve(in: lib),
              !SherpaRuntimeRelease.requiresVersionRestriction(on: operatingSystemVersion)
                || layout.isCompatible(on: operatingSystemVersion) else { return }
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil) {
            let target = paths.runtime.appendingPathComponent(file.lastPathComponent)
            guard !Self.isUsableFile(target), Self.isUsableFile(file) else { continue }
            try SherpaResourceInstaller.replaceFile(from: file, to: target)
        }
        if version == nil, let release = SherpaRuntimeRelease.knownCompatible.first(where: {
            source.lastPathComponent == SherpaModelDownloader.runtimeArchiveRootName(for: $0.version)
        }) {
            try release.version.write(to: paths.version, atomically: true, encoding: .utf8)
        }
    }
}
