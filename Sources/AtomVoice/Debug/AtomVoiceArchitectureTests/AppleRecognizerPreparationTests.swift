import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum AppleRecognizerPreparationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Apple recognizer owner stays lightweight until first preparation and uses the latest language") {
            try await MainActor.run {
                var language = "en-US"
                var languageReads = 0
                var constructed: [String] = []
                let recognizer = SpeechRecognizerController(languageProvider: {
                    languageReads += 1
                    return language
                }, recognizerFactory: {
                    constructed.append($0.identifier)
                    return nil
                })
                try expect(languageReads == 0 && constructed.isEmpty)
                language = "ja-JP"
                recognizer.updateLanguage()
                try expect(languageReads == 0 && constructed.isEmpty,
                           "Changing language before first use must not construct Apple Speech")
                recognizer.prepareRecognizerIfNeeded()
                try expect(constructed == ["ja-JP"])
                try expect(recognizer.recognitionRequest == nil)
            }
        }

        await runner.run("Apple preparation caches a locale result and rebuilds once for a changed language") {
            try await MainActor.run {
                var language = "en-US"
                var constructed: [String] = []
                let recognizer = SpeechRecognizerController(languageProvider: { language }, recognizerFactory: {
                    constructed.append($0.identifier)
                    return nil
                })
                recognizer.prepareRecognizerIfNeeded()
                recognizer.prepareRecognizerIfNeeded()
                recognizer.updateLanguage()
                _ = recognizer.stop()
                recognizer.prepareRecognizerIfNeeded()
                try expect(constructed == ["en-US"], "Stop and same-language preparation must reuse the owner")
                language = "ja-JP"
                recognizer.updateLanguage()
                recognizer.prepareRecognizerIfNeeded()
                try expect(constructed == ["en-US", "ja-JP"])
                // 首次使用也直接读取当前选择，不依赖菜单通知是否先到达。
                language = "fr-FR"
                recognizer.prepareRecognizerIfNeeded()
                try expect(constructed == ["en-US", "ja-JP", "fr-FR"])
                try expect(recognizer.recognitionRequest == nil)
            }
        }

        await runner.run("ASR provider constructs one lightweight Apple owner without preparing system Speech") {
            try await MainActor.run {
                var owners = 0
                var systemConstructions = 0
                let provider = ASREngineProvider(speechRecognizerFactory: {
                    owners += 1
                    return SpeechRecognizerController(languageProvider: { "en-US" }, recognizerFactory: { _ in
                        systemConstructions += 1
                        return nil
                    })
                })
                let engine = provider.appleEngine()
                let recognizer = provider.speechRecognizer()
                engine.updateLanguage()
                try expect(owners == 1 && systemConstructions == 0)
                try expect(engine === provider.appleEngine())
                try expect(recognizer === provider.speechRecognizer())
                try expect(engine.recognizer === recognizer)
                recognizer.prepareRecognizerIfNeeded()
                try expect(owners == 1 && systemConstructions == 1)
            }
        }

        await runner.run("Apple empty-buffer fallback never constructs a system recognizer") {
            try await checkEmptyFallback()
        }

        await runner.run("Apple buffered fallback prepares the shared owner with the current language once") {
            try await checkBufferedFallback()
        }
    }

    @MainActor private static func checkEmptyFallback() async throws {
        var constructions = 0
        let recognizer = SpeechRecognizerController(languageProvider: { "en-US" }, recognizerFactory: { _ in
            constructions += 1
            return nil
        })
        let result = await recognize(recognizer, buffers: [])
        try expect(result.isEmpty && constructions == 0 && recognizer.recognitionRequest == nil)
    }

    @MainActor private static func checkBufferedFallback() async throws {
        var language = "en-US"
        var constructed: [String] = []
        let recognizer = SpeechRecognizerController(languageProvider: { language }, recognizerFactory: {
            constructed.append($0.identifier)
            return nil
        })
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData?[0][0] = 0
        language = "ja-JP"
        let first = await recognize(recognizer, buffers: [buffer])
        let repeated = await recognize(recognizer, buffers: [buffer])
        try expect(first.isEmpty && repeated.isEmpty && constructed == ["ja-JP"])
        language = "fr-FR"
        _ = await recognize(recognizer, buffers: [buffer])
        try expect(constructed == ["ja-JP", "fr-FR"])
        // factory 返回 nil，使回退停在构造边界，不创建任何真实请求或识别任务。
        try expect(recognizer.recognitionRequest == nil)
    }

    @MainActor private static func recognize(_ recognizer: SpeechRecognizerController,
                                              buffers: [AVAudioPCMBuffer]) async -> String {
        await withCheckedContinuation { continuation in
            recognizer.recognize(buffers: buffers, onResult: { _, _ in }, completion: {
                continuation.resume(returning: $0)
            })
        }
    }
}
