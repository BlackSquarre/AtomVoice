import Foundation

protocol ASREngineProviding: AnyObject {
    var hasSherpaEngine: Bool { get }
    var isSherpaModelLoaded: Bool { get }

    func speechRecognizer() -> SpeechRecognizerController
    func appleEngine() -> AppleSpeechASREngine
    func sherpaEngine() -> SherpaOnnxASREngine
    func volcengineEngine() -> VolcengineASREngine
    func releaseSherpaEngine()
}

final class ASREngineProvider: ASREngineProviding {
    private var speechRecognizerInstance: SpeechRecognizerController?
    private var sherpaRecognizer: SherpaOnnxRecognizerController?
    private var volcengineProvider: VolcengineASRProvider?
    private var cloudRecognizer: CloudASRRecognizerController?
    private var appleASREngine: AppleSpeechASREngine?
    private var sherpaASREngine: SherpaOnnxASREngine?
    private var volcengineASREngine: VolcengineASREngine?

    var hasSherpaEngine: Bool {
        sherpaASREngine != nil
    }

    var isSherpaModelLoaded: Bool {
        sherpaASREngine?.isModelLoaded == true
    }

    func speechRecognizer() -> SpeechRecognizerController {
        if let speechRecognizerInstance { return speechRecognizerInstance }
        let recognizer = SpeechRecognizerController()
        speechRecognizerInstance = recognizer
        return recognizer
    }

    func appleEngine() -> AppleSpeechASREngine {
        if let appleASREngine { return appleASREngine }
        let engine = AppleSpeechASREngine(recognizer: speechRecognizer())
        appleASREngine = engine
        return engine
    }

    func sherpaEngine() -> SherpaOnnxASREngine {
        if let sherpaASREngine { return sherpaASREngine }
        let engine = SherpaOnnxASREngine(recognizer: sherpaRecognizerController())
        sherpaASREngine = engine
        return engine
    }

    func volcengineEngine() -> VolcengineASREngine {
        if let volcengineASREngine { return volcengineASREngine }
        let engine = VolcengineASREngine(provider: volcengineASRProvider(), recognizer: cloudASRRecognizer())
        volcengineASREngine = engine
        return engine
    }

    func releaseSherpaEngine() {
        guard sherpaASREngine != nil || sherpaRecognizer != nil else { return }
        if sherpaASREngine?.isModelLoaded == true {
            DebugLog.info("[ASREngineProvider] 释放 Sherpa 本地模型")
            sherpaASREngine?.releaseModels()
        }
        sherpaASREngine = nil
        sherpaRecognizer = nil
        DebugLog.info("[ASREngineProvider] 已释放 Sherpa 引擎实例")
    }

    private func sherpaRecognizerController() -> SherpaOnnxRecognizerController {
        if let sherpaRecognizer { return sherpaRecognizer }
        let recognizer = SherpaOnnxRecognizerController()
        sherpaRecognizer = recognizer
        return recognizer
    }

    private func volcengineASRProvider() -> VolcengineASRProvider {
        if let volcengineProvider { return volcengineProvider }
        let provider = VolcengineASRProvider()
        volcengineProvider = provider
        return provider
    }

    private func cloudASRRecognizer() -> CloudASRRecognizerController {
        if let cloudRecognizer { return cloudRecognizer }
        let recognizer = CloudASRRecognizerController(provider: volcengineASRProvider())
        cloudRecognizer = recognizer
        return recognizer
    }
}
