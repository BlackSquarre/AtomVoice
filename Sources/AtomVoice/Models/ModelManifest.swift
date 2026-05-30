import Foundation

/// Sherpa 模型文件清单（Sherpa Model File Manifest）
/// 描述一个模型目录里 encoder/decoder/joiner/tokens 的实际文件名；
/// 不同模型 zip 包命名差异极大，统一通过磁盘扫描发现而非硬编码
/// (Describes the actual file names within a model directory.
///  Sherpa archives use very different naming conventions, so we
///  discover by scanning the disk rather than hardcoding.)
struct ModelManifest: Codable, Equatable {
    enum Family: String, Codable, Equatable {
        case onlineTransducer
        case onlineParaformer
    }

    let family: Family
    /// 相对于模型目录的文件路径（多数模型为 basename，部分 icefall 包含 exp/ 与 data/lang_char/ 子目录）
    /// (Paths relative to the model directory — usually basenames; some icefall archives use subdirectories.)
    let encoder: String
    let decoder: String
    let joiner: String?
    let tokens: String

    static let filename = "atomvoice-manifest.json"

    init(
        family: Family = .onlineTransducer,
        encoder: String,
        decoder: String,
        joiner: String? = nil,
        tokens: String
    ) {
        self.family = family
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey {
        case family
        case encoder
        case decoder
        case joiner
        case tokens
    }

    /// 兼容旧 manifest：历史版本没有 family 字段，默认按 transducer 读取。
    /// (Backward-compatible decoding: historical manifests had no family field, default to transducer.)
    init(from source: Decoder) throws {
        let container = try source.container(keyedBy: CodingKeys.self)
        family = try container.decodeIfPresent(Family.self, forKey: .family) ?? .onlineTransducer
        encoder = try container.decode(String.self, forKey: .encoder)
        decoder = try container.decode(String.self, forKey: .decoder)
        joiner = try container.decodeIfPresent(String.self, forKey: .joiner)
        tokens = try container.decode(String.self, forKey: .tokens)
    }

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
        guard SherpaModelPreset.isUsableFile(directory.appendingPathComponent(encoder)),
              SherpaModelPreset.isUsableFile(directory.appendingPathComponent(decoder)),
              SherpaModelPreset.isUsableFile(directory.appendingPathComponent(tokens)) else {
            return false
        }

        switch family {
        case .onlineTransducer:
            guard let joiner else { return false }
            return SherpaModelPreset.isUsableFile(directory.appendingPathComponent(joiner))
        case .onlineParaformer:
            return true
        }
    }

    /// 扫描目录推断 manifest（Scan directory and infer manifest）
    /// 规则（Rules）：
    /// - 递归扫描模型目录，支持 icefall 包中 exp/*.onnx + data/lang_char/tokens.txt 的布局
    /// - tokens：精确文件名 tokens.txt（exact filename）
    /// - encoder/joiner：取名字含 "encoder"/"joiner" 的 .onnx 文件，多个候选时偏好 int8 量化版（smaller, common pairing）
    /// - decoder：取名字含 "decoder" 的 .onnx 文件，多个候选时偏好非 int8 版本（保留精度）
    static func discover(in directory: URL) -> ModelManifest? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let regular = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        let onnx = regular.filter { $0.pathExtension.lowercased() == "onnx" && SherpaModelPreset.isUsableFile($0) }

        func relativePath(_ url: URL) -> String {
            let base = directory.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
            return String(path.dropFirst(base.count + 1))
        }

        let isInt8: (URL) -> Bool = { $0.lastPathComponent.lowercased().contains("int8") }

        func pick(component: String, preferInt8: Bool) -> String? {
            let candidates = onnx.filter { $0.lastPathComponent.lowercased().contains(component) }
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return relativePath(candidates[0]) }
            let int8Hits = candidates.filter(isInt8)
            let nonInt8 = candidates.filter { !isInt8($0) }
            let selected: URL
            if preferInt8 {
                selected = int8Hits.first ?? nonInt8.first ?? candidates[0]
            } else {
                selected = nonInt8.first ?? int8Hits.first ?? candidates[0]
            }
            return relativePath(selected)
        }

        let tokens = regular.first { $0.lastPathComponent == "tokens.txt" && SherpaModelPreset.isUsableFile($0) }
        guard let tokensName = tokens.map(relativePath) else { return nil }

        if let encoder = pick(component: "encoder", preferInt8: true),
           let decoder = pick(component: "decoder", preferInt8: false),
           let joiner = pick(component: "joiner", preferInt8: true) {
            return ModelManifest(
                family: .onlineTransducer,
                encoder: encoder,
                decoder: decoder,
                joiner: joiner,
                tokens: tokensName
            )
        }

        func pickParaformerPair() -> (String, String)? {
            let encoders = onnx.filter { $0.lastPathComponent.lowercased().contains("encoder") }
            let decoders = onnx.filter { $0.lastPathComponent.lowercased().contains("decoder") }
            guard !encoders.isEmpty, !decoders.isEmpty else { return nil }

            let int8Encoders = encoders.filter(isInt8)
            let plainEncoders = encoders.filter { !isInt8($0) }
            let int8Decoders = decoders.filter(isInt8)
            let plainDecoders = decoders.filter { !isInt8($0) }

            if let encoder = int8Encoders.first, let decoder = int8Decoders.first {
                return (relativePath(encoder), relativePath(decoder))
            }
            if let encoder = plainEncoders.first, let decoder = plainDecoders.first {
                return (relativePath(encoder), relativePath(decoder))
            }

            let selectedEncoder = int8Encoders.first ?? plainEncoders.first ?? encoders[0]
            let selectedDecoder = int8Decoders.first ?? plainDecoders.first ?? decoders[0]
            return (relativePath(selectedEncoder), relativePath(selectedDecoder))
        }

        if let (encoder, decoder) = pickParaformerPair() {
            return ModelManifest(
                family: .onlineParaformer,
                encoder: encoder,
                decoder: decoder,
                joiner: nil,
                tokens: tokensName
            )
        }

        return nil
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
