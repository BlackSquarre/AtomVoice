import Foundation

/// Sherpa 模型预设配置（Sherpa Model Preset Configuration）
struct SherpaModelPreset {
    let id: String
    let language: String
    let archiveURL: URL
    let archiveName: String
    let extractedDirName: String
    let encoderFile: String
    let decoderFile: String
    let joinerFile: String
    let tokensFile: String
    let sizeMB: Int

    /// 显示名称，格式: "id (体积)"（Display name in format: "id (size)"）
    var displayName: String {
        "\(id) (\(sizeMB)MB)"
    }

    /// 所有预设模型（All preset models）
    static let allPresets: [SherpaModelPreset] = [
        // 中文（Chinese）
        SherpaModelPreset(
            id: "zh-14M",
            language: "zh-CN",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 15
        ),
        SherpaModelPreset(
            id: "zh-multi",
            language: "zh-CN",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12",
            encoderFile: "encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx",
            decoderFile: "decoder-epoch-20-avg-1-chunk-16-left-128.onnx",
            joinerFile: "joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 73
        ),
        SherpaModelPreset(
            id: "zh-large",
            language: "zh-CN",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30",
            encoderFile: "encoder.int8.onnx",
            decoderFile: "decoder.onnx",
            joinerFile: "joiner.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 160
        ),
        SherpaModelPreset(
            id: "zh-xlarge",
            language: "zh-CN",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30",
            encoderFile: "encoder.int8.onnx",
            decoderFile: "decoder.onnx",
            joinerFile: "joiner.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 736
        ),
        // 中英双语（Bilingual Chinese + English）
        SherpaModelPreset(
            id: "bilingual-small",
            language: "bilingual",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 80
        ),
        SherpaModelPreset(
            id: "bilingual",
            language: "bilingual",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 260
        ),
        // 英文（English）
        SherpaModelPreset(
            id: "en-20M",
            language: "en-US",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 20
        ),
        SherpaModelPreset(
            id: "en-standard",
            language: "en-US",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-en-2023-06-26",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 260
        ),
        // 韩语（Korean）
        SherpaModelPreset(
            id: "korean",
            language: "ko-KR",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-korean-2024-06-16.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-korean-2024-06-16.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-korean-2024-06-16",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 290
        ),
        // 法语（French）
        SherpaModelPreset(
            id: "french",
            language: "fr-FR",
            archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2")!,
            archiveName: "sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2",
            extractedDirName: "sherpa-onnx-streaming-zipformer-fr-2023-04-14",
            encoderFile: "encoder-epoch-99-avg-1.int8.onnx",
            decoderFile: "decoder-epoch-99-avg-1.onnx",
            joinerFile: "joiner-epoch-99-avg-1.int8.onnx",
            tokensFile: "tokens.txt",
            sizeMB: 260
        ),
    ]

    /// 按语言分组的预设模型（Presets grouped by language）
    static var presetsByLanguage: [String: [SherpaModelPreset]] {
        Dictionary(grouping: allPresets, by: { $0.language })
    }

    /// 获取当前语言的可用模型（Get available models for current language）
    static func presetsForCurrentLanguage() -> [SherpaModelPreset] {
        let currentLang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        var presets: [SherpaModelPreset] = []

        // 添加当前语言的模型
        if let langPresets = presetsByLanguage[currentLang] {
            presets.append(contentsOf: langPresets)
        }

        // 添加双语模型
        if let bilingualPresets = presetsByLanguage["bilingual"] {
            presets.append(contentsOf: bilingualPresets)
        }

        return presets
    }

    /// 获取当前选中的模型（Get currently selected model）
    static var current: SherpaModelPreset {
        let currentID = UserDefaults.standard.string(forKey: "sherpaModelPresetID") ?? defaultModelID
        return allPresets.first(where: { $0.id == currentID }) ?? defaultPreset
    }

    /// 默认模型 ID（根据内存容量）（Default model ID based on memory size）
    static var defaultModelID: String {
        let memoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        return memoryGB <= 8 ? "zh-14M" : "zh-multi"
    }

    /// 默认预设（Default preset）
    static var defaultPreset: SherpaModelPreset {
        allPresets.first(where: { $0.id == defaultModelID }) ?? allPresets[0]
    }

    /// 检查模型是否已下载（Check if model is downloaded）
    var isDownloaded: Bool {
        let modelsDir = SherpaOnnxRecognizerController.modelsDirectory
        let modelDir = modelsDir.appendingPathComponent(extractedDirName, isDirectory: true)
        let encoderPath = modelDir.appendingPathComponent(encoderFile)
        let decoderPath = modelDir.appendingPathComponent(decoderFile)
        let joinerPath = modelDir.appendingPathComponent(joinerFile)
        let tokensPath = modelDir.appendingPathComponent(tokensFile)

        return FileManager.default.fileExists(atPath: encoderPath.path) &&
               FileManager.default.fileExists(atPath: decoderPath.path) &&
               FileManager.default.fileExists(atPath: joinerPath.path) &&
               FileManager.default.fileExists(atPath: tokensPath.path)
    }

    // MARK: - 镜像站逻辑（Mirror site logic）

    /// 是否需要使用镜像站（Whether to use mirror site）
    static var needsMirror: Bool {
        // 检查缓存
        if let cached = UserDefaults.standard.object(forKey: "sherpaMirrorCached") as? Bool {
            return cached
        }

        // 尝试访问 GitHub
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let url = URL(string: "https://github.com")!
        let task = URLSession.shared.dataTask(with: url) { _, response, error in
            if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)  // 5秒超时
        task.cancel()

        let result = !success  // 如果访问失败，需要镜像站
        UserDefaults.standard.set(result, forKey: "sherpaMirrorCached")
        return result
    }

    /// 重置镜像站缓存（Reset mirror site cache）
    static func resetMirrorCache() {
        UserDefaults.standard.removeObject(forKey: "sherpaMirrorCached")
    }

    /// 获取下载 URL（带镜像站支持）（Get download URL with mirror site support）
    var downloadURL: URL {
        if Self.needsMirror {
            return URL(string: "https://ghproxy.com/\(archiveURL.absoluteString)")!
        }
        return archiveURL
    }

    /// 获取模型目录（Get model directory）
    var modelDirectory: URL {
        SherpaOnnxRecognizerController.modelsDirectory
            .appendingPathComponent(extractedDirName, isDirectory: true)
    }
}
