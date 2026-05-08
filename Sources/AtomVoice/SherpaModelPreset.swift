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

    /// 内置预设（Built-in presets）
    /// 字段只描述哪里下载、解压到哪、占多大；不描述 .onnx 文件名（这些由 ModelManifest 扫描）
    /// (Fields describe where to download, where to extract, and size; not the .onnx filenames — those come from ModelManifest discovery)
    static let builtInPresets: [SherpaModelPreset] = [
        // 中文（Chinese）
        builtIn(id: "zh-14M",     lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile.tar.bz2", sizeMB: 15),
        builtIn(id: "zh-multi",   lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2", sizeMB: 73),
        builtIn(id: "zh-large",   lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30.tar.bz2",       sizeMB: 160),
        builtIn(id: "zh-xlarge",  lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30.tar.bz2", sizeMB: 736),
        // 中英双语（Bilingual Chinese + English）
        builtIn(id: "bilingual-small", lang: "bilingual", archive: "sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2", sizeMB: 80),
        builtIn(id: "bilingual",       lang: "bilingual", archive: "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2",       sizeMB: 260),
        // 英文（English）
        builtIn(id: "en-20M",     lang: "en-US",     archive: "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2", sizeMB: 20),
        builtIn(id: "en-standard",lang: "en-US",     archive: "sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",     sizeMB: 260),
        // 日语（Japanese, ReazonSpeech）
        builtIn(id: "japanese",   lang: "ja-JP",     archive: "sherpa-onnx-streaming-zipformer-ja-reazonspeech-2024-06-24.tar.bz2", sizeMB: 280),
        // 韩语 / 法语
        builtIn(id: "korean",     lang: "ko-KR",     archive: "sherpa-onnx-streaming-zipformer-korean-2024-06-16.tar.bz2", sizeMB: 290),
        builtIn(id: "french",     lang: "fr-FR",     archive: "sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2",     sizeMB: 260),
    ]

    private static func builtIn(id: String, lang: String, archive: String, sizeMB: Int) -> SherpaModelPreset {
        // archive 文件名去掉 .tar.bz2 即为解压后的顶层目录名（Sherpa 官方约定）
        // (Archive name minus .tar.bz2 equals top-level extracted directory — Sherpa's convention)
        let extracted = archive.replacingOccurrences(of: ".tar.bz2", with: "")
        let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(archive)")!
        return SherpaModelPreset(
            id: id, language: lang,
            archiveURL: url, archiveName: archive,
            extractedDirName: extracted, sizeMB: sizeMB,
            isImported: false
        )
    }

    /// 内置 + 已导入的所有预设（Built-in + imported presets combined）
    static var allPresets: [SherpaModelPreset] {
        builtInPresets + SherpaImportedPresetStore.shared.presets()
    }

    /// 按语言分组（Presets grouped by language）
    static var presetsByLanguage: [String: [SherpaModelPreset]] {
        Dictionary(grouping: allPresets, by: { $0.language })
    }

    /// Sherpa 识别语言独立 UserDefaults key，与 UI 语言解耦
    /// (Sherpa recognition language defaults key — decoupled from UI language)
    static let recognitionLanguageKey = "sherpaRecognitionLanguage"

    /// 当前 Sherpa 识别语言；首次读取时回退到 UI 语言以保持已有用户行为
    /// (Current Sherpa recognition language; first read falls back to UI language for existing users)
    static var recognitionLanguage: String {
        if let lang = UserDefaults.standard.string(forKey: recognitionLanguageKey), !lang.isEmpty {
            return lang
        }
        return UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
    }

    /// 支持作为识别语言的代码列表（按 UI 显示顺序）（Supported recognition language codes, in UI display order）
    /// 全部 App 支持语言都列出；没有内置 preset 的语言依赖用户自行导入第三方 sherpa 模型
    /// (All app-supported languages listed; languages without built-in presets rely on user-imported third-party models)
    static let supportedRecognitionLanguages: [String] = [
        "zh-CN", "zh-TW", "en-US", "bilingual", "ja-JP", "ko-KR", "es-ES", "fr-FR", "de-DE",
    ]

    /// 当前识别语言下可用的 preset；imported preset 的语言可能不在 supportedRecognitionLanguages 中，仍照样列出
    /// (Presets available under current recognition language; imported presets with arbitrary language tags are still surfaced)
    static func presetsForRecognitionLanguage() -> [SherpaModelPreset] {
        presets(forRecognitionLanguage: recognitionLanguage)
    }

    static func presets(forRecognitionLanguage lang: String) -> [SherpaModelPreset] {
        var presets: [SherpaModelPreset] = []
        if let primary = presetsByLanguage[lang] {
            presets.append(contentsOf: primary)
        }
        if lang != "bilingual", let bi = presetsByLanguage["bilingual"] {
            presets.append(contentsOf: bi)
        }
        return presets
    }

    /// 当前选中的预设（Currently selected preset）
    static var current: SherpaModelPreset {
        let currentID = UserDefaults.standard.string(forKey: "sherpaModelPresetID") ?? defaultModelID
        return allPresets.first(where: { $0.id == currentID }) ?? defaultPreset
    }

    /// 默认预设 ID：综合识别语言与物理内存（Default preset ID: combined recognition language and physical memory）
    static var defaultModelID: String {
        defaultModelID(forRecognitionLanguage: recognitionLanguage)
    }

    static func defaultModelID(forRecognitionLanguage lang: String) -> String {
        let memoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let lowMem = memoryGB <= 8
        switch lang {
        case "zh-CN":     return lowMem ? "zh-14M" : "zh-multi"
        case "en-US":     return lowMem ? "en-20M" : "en-standard"
        case "bilingual": return lowMem ? "bilingual-small" : "bilingual"
        case "ja-JP":     return "japanese"
        case "ko-KR":     return "korean"
        case "fr-FR":     return "french"
        // 无内置预设的语言：取该语言下第一个已导入预设；都没有则回退到中文默认
        // (Languages with no built-in: pick first imported preset; fall back to zh default if none)
        case "zh-TW", "es-ES", "de-DE":
            if let imported = SherpaImportedPresetStore.shared.presets().first(where: { $0.language == lang }) {
                return imported.id
            }
            return lowMem ? "zh-14M" : "zh-multi"
        default:
            return lowMem ? "zh-14M" : "zh-multi"
        }
    }

    static var defaultPreset: SherpaModelPreset {
        allPresets.first(where: { $0.id == defaultModelID }) ?? builtInPresets[0]
    }

    /// 解析此预设的 manifest（Resolve manifest for this preset）
    func resolveManifest() -> ModelManifest? {
        ModelManifest.resolve(in: modelDirectory)
    }

    /// 模型是否已下载且可用：manifest 能解析出 4 个文件且文件齐
    /// (Whether the model is downloaded and usable: manifest resolvable, all 4 files present)
    var isDownloaded: Bool {
        resolveManifest() != nil
    }

    /// 检查文件是否可用：存在、非目录、且大小 > 0
    /// (Whether file is usable: exists, not directory, size > 0)
    static func isUsableFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    // MARK: - 镜像站逻辑（Mirror site logic）

    /// 可用的 GitHub 镜像前缀，按优先级排序（Available GitHub mirror prefixes, in priority order）
    static let mirrorPrefixes: [String] = [
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://gh.llkk.cc/",
    ]

    private static let mirrorCacheKey = "sherpaMirrorCached"

    static var prefersMirror: Bool {
        UserDefaults.standard.object(forKey: mirrorCacheKey) as? Bool ?? false
    }

    static func probeMirrorAsync() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(string: "https://github.com")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: request) { _, response, error in
                let reachable = error == nil &&
                    (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } == true
                UserDefaults.standard.set(!reachable, forKey: mirrorCacheKey)
            }
            task.resume()
        }
    }

    static func resetMirrorCache() {
        UserDefaults.standard.removeObject(forKey: mirrorCacheKey)
    }

    static func candidateURLs(for githubURL: URL) -> [URL] {
        let raw = githubURL.absoluteString
        let mirrored: [URL] = mirrorPrefixes.compactMap { URL(string: $0 + raw) }
        if prefersMirror {
            return mirrored + [githubURL]
        } else {
            return [githubURL] + mirrored
        }
    }

    /// 此预设的下载候选 URL；导入预设无下载源，返回空数组
    /// (Download candidate URLs; imported presets have no source, returns empty array)
    var downloadURLs: [URL] {
        guard let archiveURL else { return [] }
        return Self.candidateURLs(for: archiveURL)
    }

    /// 模型解压目录（Model directory after extraction）
    var modelDirectory: URL {
        SherpaOnnxRecognizerController.modelsDirectory
            .appendingPathComponent(extractedDirName, isDirectory: true)
    }
}
