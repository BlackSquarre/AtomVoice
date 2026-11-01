import Foundation

/// 内置模型目录只描述资源，不读取选择设置或执行网络请求。
enum SherpaModelCatalog {
    /// 内置预设（Built-in presets）
    /// 字段只描述哪里下载、解压到哪、占多大；不描述 .onnx 文件名（这些由 ModelManifest 扫描）
    /// (Fields describe where to download, where to extract, and size; not the .onnx filenames — those come from ModelManifest discovery)
    static let builtInPresets: [SherpaModelPreset] = {
        var presets: [SherpaModelPreset] = [
        // 中文（Chinese）
        builtIn(id: "zh-14M",     lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile.tar.bz2", sizeMB: 52),
        builtIn(id: "zh-multi",   lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2", sizeMB: 296),
        builtIn(id: "zh-large",   lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30.tar.bz2",       sizeMB: 126),
        builtIn(id: "zh-xlarge",  lang: "zh-CN",     archive: "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30.tar.bz2", sizeMB: 570),
        // 中英双语（Bilingual Chinese + English）
        builtIn(id: "bilingual-small", lang: "bilingual", archive: "sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2", sizeMB: 437),
        builtIn(id: "bilingual",       lang: "bilingual", archive: "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2",       sizeMB: 488),
        builtIn(id: "bilingual-paraformer", lang: "bilingual", archive: "sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2", sizeMB: 999),
        // 英文（English）
        builtIn(id: "en-20M",     lang: "en-US",     archive: "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2", sizeMB: 122),
        builtIn(id: "en-standard",lang: "en-US",     archive: "sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",     sizeMB: 296),
        // 日语（Japanese, ReazonSpeech）
        builtIn(id: "japanese",   lang: "ja-JP",     archive: "sherpa-onnx-streaming-zipformer-ja-reazonspeech-2024-06-24.tar.bz2", sizeMB: 280),
        // 韩语 / 法语（Korean / French）
        builtIn(id: "korean",     lang: "ko-KR",     archive: "sherpa-onnx-streaming-zipformer-korean-2024-06-16.tar.bz2", sizeMB: 399),
        builtIn(id: "french",     lang: "fr-FR",     archive: "sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2",     sizeMB: 380),
        ]

        #if DEBUG_BUILD
        // Debug 专属候选模型，用于验证新模型兼容性；正式版不展示。
        // (Debug-only candidate models for validating new model compatibility; hidden in release builds.)
        presets.append(contentsOf: [
            builtIn(id: "debug-zh-2025", lang: "zh-CN", archive: "sherpa-onnx-streaming-zipformer-zh-2025-06-30.tar.bz2", sizeMB: 566),
            builtIn(id: "debug-wenetspeech", lang: "zh-CN", archive: "icefall-asr-zipformer-streaming-wenetspeech-20230615.tar.bz2", sizeMB: 316),
            builtIn(id: "debug-conformer-en", lang: "en-US", archive: "sherpa-onnx-streaming-conformer-en-2023-05-09.tar.bz2", sizeMB: 626),
        ])
        #endif

        return presets
    }()

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

}
