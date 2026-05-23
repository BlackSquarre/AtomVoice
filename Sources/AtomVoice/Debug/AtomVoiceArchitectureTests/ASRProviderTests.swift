import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum ASRProviderTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("ASR provider shares Apple stack instances") {
            let provider = ASREngineProvider()
            let speechRecognizer = provider.speechRecognizer()
            let appleEngine = provider.appleEngine()

            try expect(speechRecognizer === provider.speechRecognizer())
            try expect(appleEngine === provider.appleEngine())
            try expect(appleEngine.recognizer === speechRecognizer)
        }
        await runner.run("ASR provider releases local engine without model load") {
            let provider = ASREngineProvider()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let sherpaEngine = provider.sherpaEngine()
            try expect(provider.hasSherpaEngine)
            try expect(sherpaEngine === provider.sherpaEngine())
            try expect(!provider.isSherpaModelLoaded)

            provider.releaseSherpaEngine()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let recreatedSherpaEngine = provider.sherpaEngine()
            try expect(recreatedSherpaEngine !== sherpaEngine)
        }
        await runner.run("ASR provider shares cloud engine instance") {
            let provider = ASREngineProvider()
            let engine = provider.volcengineEngine()

            try expect(engine === provider.volcengineEngine())
        }
        await runner.run("ASR provider returns stable RecognitionSession wrappers") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let apple = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let appleAgain = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let sherpa = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            let doubao = provider.recognitionSession(for: VolcengineASRSettings.engineCode, audioEngine: audioEngine)

            try expect((apple as AnyObject) === (appleAgain as AnyObject))
            try expect(apple.code == ASREngineRegistry.appleCode)
            try expect(apple.preferredAudioFormat == nil)
            try expect(apple.supportsLiveInsertion)
            try expect(!apple.supportsServerFallback)
            try expect(sherpa.preferredAudioFormat == .voice16k)
            try expect(!sherpa.supportsLiveInsertion)
            try expect(doubao.preferredAudioFormat == .voice16k)
            try expect(doubao.supportsServerFallback)
        }
        await runner.run("ASR provider rebuilds Sherpa RecognitionSession on release") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let session = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            provider.releaseSherpaEngine()
            let recreated = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)

            try expect((session as AnyObject) !== (recreated as AnyObject))
            try expect(!provider.isSherpaModelLoaded)
        }
        await runner.run("ASR registry normalizes unknown engine codes") {
            let registry = ASREngineRegistry(descriptors: [.sherpaOnnx, .apple, .volcengine])

            try expect(registry.normalizedCode(for: nil) == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: "missing") == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: ASREngineRegistry.sherpaCode) == ASREngineRegistry.sherpaCode)
        }
        await runner.run("ASR registry keeps cloud boundary explicit") {
            let registry = ASREngineRegistry.shared

            try expect(registry.isCloud(VolcengineASRSettings.engineCode))
            try expect(!registry.isCloud(ASREngineRegistry.appleCode))
            try expect(!registry.isCloud(ASREngineRegistry.sherpaCode))
            try expect(registry.descriptor(for: VolcengineASRSettings.engineCode)?.requiresCredential == true)
            try expect(registry.descriptor(for: ASREngineRegistry.sherpaCode)?.isOffline == true)
        }
    }
}
