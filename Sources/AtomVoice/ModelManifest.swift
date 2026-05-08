import Foundation

/// Sherpa 模型文件清单（Sherpa Model File Manifest）
/// 描述一个模型目录里 encoder/decoder/joiner/tokens 的实际文件名；
/// 不同模型 zip 包命名差异极大，统一通过磁盘扫描发现而非硬编码
/// (Describes the actual file names within a model directory.
///  Sherpa archives use very different naming conventions, so we
///  discover by scanning the disk rather than hardcoding.)
struct ModelManifest: Codable, Equatable {
    /// 相对于模型目录的文件名（仅 basename，不带路径）
    /// (Filenames relative to the model directory — basename only)
    let encoder: String
    let decoder: String
    let joiner: String
    let tokens: String

    static let filename = "atomvoice-manifest.json"

    /// 读取已写入的 manifest，并校验文件确实可用；任一缺失返回 nil
    /// (Load saved manifest and verify all listed files are still usable; nil if any missing)
    static func load(from directory: URL) -> ModelManifest? {
        let path = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: path),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else { return nil }
        guard manifest.isComplete(in: directory) else { return nil }
        return manifest
    }

    /// 写 manifest 到目录（Save manifest to directory）
    func save(to directory: URL) throws {
        let path = directory.appendingPathComponent(Self.filename)
        let data = try JSONEncoder().encode(self)
        try data.write(to: path, options: .atomic)
    }

    /// 检查所有文件都存在且非空（Check all listed files exist and non-empty）
    func isComplete(in directory: URL) -> Bool {
        SherpaModelPreset.isUsableFile(directory.appendingPathComponent(encoder))
            && SherpaModelPreset.isUsableFile(directory.appendingPathComponent(decoder))
            && SherpaModelPreset.isUsableFile(directory.appendingPathComponent(joiner))
            && SherpaModelPreset.isUsableFile(directory.appendingPathComponent(tokens))
    }

    /// 扫描目录推断 manifest（Scan directory and infer manifest）
    /// 规则（Rules）：
    /// - tokens：精确文件名 tokens.txt（exact filename）
    /// - encoder/joiner：取名字含 "encoder"/"joiner" 的 .onnx 文件，多个候选时偏好 int8 量化版（smaller, common pairing）
    /// - decoder：取名字含 "decoder" 的 .onnx 文件，多个候选时偏好非 int8 版本（保留精度）
    static func discover(in directory: URL) -> ModelManifest? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let regular = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        }
        let onnx = regular.filter { $0.pathExtension.lowercased() == "onnx" && SherpaModelPreset.isUsableFile($0) }

        func pick(component: String, preferInt8: Bool) -> String? {
            let candidates = onnx.filter { $0.lastPathComponent.lowercased().contains(component) }
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return candidates[0].lastPathComponent }
            let isInt8: (URL) -> Bool = { $0.lastPathComponent.lowercased().contains("int8") }
            let int8Hits = candidates.filter(isInt8)
            let nonInt8 = candidates.filter { !isInt8($0) }
            if preferInt8 {
                return (int8Hits.first ?? nonInt8.first ?? candidates[0]).lastPathComponent
            } else {
                return (nonInt8.first ?? int8Hits.first ?? candidates[0]).lastPathComponent
            }
        }

        guard let encoder = pick(component: "encoder", preferInt8: true),
              let decoder = pick(component: "decoder", preferInt8: false),
              let joiner = pick(component: "joiner", preferInt8: true)
        else { return nil }

        let tokens = regular.first { $0.lastPathComponent == "tokens.txt" && SherpaModelPreset.isUsableFile($0) }
        guard let tokensName = tokens?.lastPathComponent else { return nil }

        return ModelManifest(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokensName)
    }

    /// 综合接入点：先读已保存的 manifest，缺失则扫描；扫描成功后写回缓存
    /// (Combined entry: load saved manifest first; if absent, discover and write back)
    static func resolve(in directory: URL) -> ModelManifest? {
        if let cached = load(from: directory) { return cached }
        guard let discovered = discover(in: directory) else { return nil }
        try? discovered.save(to: directory)
        return discovered
    }
}
