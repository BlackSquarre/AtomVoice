import Foundation

/// Sherpa 模型预设配置（Sherpa Model Preset Configuration）
/// 不再持有 encoder/decoder/joiner/tokens 文件名；这些通过磁盘扫描动态发现
/// (No longer holds encoder/decoder/joiner/tokens filenames; they are discovered from disk)
struct SherpaModelPreset {
    let id: String
    let language: String
    let archiveURL: URL?         // 内置预设的 GitHub 直链；导入预设为 nil（GitHub URL for built-ins; nil for imported）
    let archiveName: String?     // 同上（same as above）
    let extractedDirName: String // 解压后顶层目录名（top-level directory name after extraction）
    let sizeMB: Int
    let isImported: Bool

    /// 是否为可下载的内置预设（Whether this is a downloadable built-in preset）
    var isBuiltIn: Bool { !isImported && archiveURL != nil }

    /// 显示名称，格式: "id (体积)"（Display name in format: "id (size)"）
    var displayName: String {
        "\(id) (\(sizeMB)MB)"
    }

    static var builtInPresets: [SherpaModelPreset] { SherpaModelCatalog.builtInPresets }
    static var allPresets: [SherpaModelPreset] { SherpaModelSelection.shared.allPresets }
    static var presetsByLanguage: [String: [SherpaModelPreset]] { Dictionary(grouping: allPresets, by: { $0.language }) }
    static let recognitionLanguageKey = AppSettings.Keys.sherpaRecognitionLanguage
    static var recognitionLanguage: String { SherpaModelSelection.shared.recognitionLanguage }
    static let supportedRecognitionLanguages = ["zh-CN", "zh-TW", "en-US", "bilingual", "ja-JP", "ko-KR", "es-ES", "fr-FR", "de-DE"]
    static func presetsForRecognitionLanguage() -> [SherpaModelPreset] { presets(forRecognitionLanguage: recognitionLanguage) }
    static func presets(forRecognitionLanguage language: String) -> [SherpaModelPreset] { SherpaModelSelection.shared.presets(for: language) }
    static var current: SherpaModelPreset { SherpaModelSelection.shared.current }
    static var defaultModelID: String { defaultModelID(forRecognitionLanguage: recognitionLanguage) }
    static func defaultModelID(forRecognitionLanguage language: String) -> String { SherpaModelSelection.shared.defaultModelID(for: language) }
    static var defaultPreset: SherpaModelPreset { SherpaModelSelection.shared.defaultPreset }

    /// 解析此预设的 manifest（Resolve manifest for this preset）
    func resolveManifest() -> ModelManifest? {
        ModelManifest.resolve(in: modelDirectory)
    }

    /// 纯资源查询：按模型 family 检查必要文件，不写 manifest 缓存。
    var isDownloaded: Bool {
        ModelManifest.inspect(in: modelDirectory) != nil
    }

    /// 检查文件是否可用：存在、非目录、且大小 > 0
    /// (Whether file is usable: exists, not directory, size > 0)
    static func isUsableFile(_ url: URL) -> Bool {
        SherpaResources.isUsableFile(url)
    }

    static var mirrorPrefixes: [String] { SherpaDownloadSources.mirrorPrefixes }
    static var prefersMirror: Bool { SherpaDownloadSources.prefersMirror }
    static func probeMirrorAsync() { SherpaDownloadSources.probeMirrorAsync() }
    static func resetMirrorCache() { SherpaDownloadSources.resetMirrorCache() }
    static func candidateURLs(for url: URL) -> [URL] { SherpaDownloadSources.candidateURLs(for: url) }

    /// 此预设的下载候选 URL；导入预设无下载源，返回空数组
    /// (Download candidate URLs; imported presets have no source, returns empty array)
    var downloadURLs: [URL] {
        guard let archiveURL else { return [] }
        return Self.candidateURLs(for: archiveURL)
    }

    /// 模型解压目录（Model directory after extraction）
    var modelDirectory: URL {
        SherpaResourcePaths.current.models
            .appendingPathComponent(extractedDirName, isDirectory: true)
    }
}
