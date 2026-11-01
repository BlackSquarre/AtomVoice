import Foundation

/// 资源路径不依赖识别器；保留所有既有用户目录。
struct SherpaResourcePaths {
    static let current = SherpaResourcePaths(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AtomVoice/SherpaOnnx", isDirectory: true))
    static let punctuationName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
    static let runtimeLibraries = ["libsherpa-onnx-c-api.dylib", "libonnxruntime.1.24.4.dylib"]
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
    init(paths: SherpaResourcePaths = .current) { self.paths = paths }

    func status(for preset: SherpaModelPreset) -> SherpaResourceStatus {
        .init(runtimeReady: SherpaResourcePaths.runtimeLibraries.allSatisfy { Self.isUsableFile(paths.runtime.appendingPathComponent($0)) },
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
        guard let contents = try? FileManager.default.contentsOfDirectory(at: paths.support, includingPropertiesForKeys: nil),
              !contents.isEmpty else { return }
        let version = (try? String(contentsOf: paths.version, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = version.map { SherpaModelDownloader.runtimeArchiveRootName(for: $0) }
        guard let source = contents.first(where: { $0.lastPathComponent == preferredName })
            ?? contents.first(where: { $0.lastPathComponent.contains("-osx-universal2-shared-no-tts-lib") }) else { return }
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        for name in SherpaResourcePaths.runtimeLibraries {
            let target = paths.runtime.appendingPathComponent(name)
            let source = source.appendingPathComponent("lib/" + name)
            guard !Self.isUsableFile(target), Self.isUsableFile(source) else { continue }
            try SherpaResourceInstaller.replaceFile(from: source, to: target)
        }
    }
}
