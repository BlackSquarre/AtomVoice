import Foundation

protocol ASREngineProviding: AnyObject {
    var hasSherpaEngine: Bool { get }
    var isSherpaModelLoaded: Bool { get }

    func speechRecognizer() -> SpeechRecognizerController
    func appleEngine() -> AppleSpeechASREngine
    func sherpaEngine() -> SherpaOnnxASREngine
    func volcengineEngine() -> VolcengineASREngine
    func recognitionSession(for code: String, audioEngine: AudioEngineController) -> any RecognitionSession
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
    private weak var recognitionSessionAudioEngine: AudioEngineController?
    private var appleRecognitionSession: AppleRecognitionSession?
    private var sherpaRecognitionSession: SherpaRecognitionSession?
    private var doubaoRecognitionSession: DoubaoRecognitionSession?

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

    func recognitionSession(for code: String, audioEngine: AudioEngineController) -> any RecognitionSession {
        resetRecognitionSessionsIfNeeded(for: audioEngine)
        switch code {
        case VolcengineASRSettings.engineCode:
            if let doubaoRecognitionSession { return doubaoRecognitionSession }
            let session = DoubaoRecognitionSession(
                cloudEngine: volcengineEngine(),
                appleEngine: appleEngine(),
                speechRecognizerProvider: { [weak self] in
                    self?.speechRecognizer() ?? SpeechRecognizerController()
                },
                audioEngine: audioEngine
            )
            doubaoRecognitionSession = session
            return session
        case ASREngineRegistry.sherpaCode:
            if let sherpaRecognitionSession { return sherpaRecognitionSession }
            let session = SherpaRecognitionSession(engine: sherpaEngine())
            sherpaRecognitionSession = session
            return session
        default:
            if let appleRecognitionSession { return appleRecognitionSession }
            let session = AppleRecognitionSession(engine: appleEngine())
            appleRecognitionSession = session
            return session
        }
    }

    func releaseSherpaEngine() {
        guard sherpaASREngine != nil || sherpaRecognizer != nil else { return }
        sherpaASREngine?.releaseModels()
        // 保留轻量 owner，释放在其串行队列执行；下一轮加载排在释放之后。
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

    private func resetRecognitionSessionsIfNeeded(for audioEngine: AudioEngineController) {
        guard recognitionSessionAudioEngine !== audioEngine else { return }
        appleRecognitionSession = nil
        sherpaRecognitionSession = nil
        doubaoRecognitionSession = nil
        recognitionSessionAudioEngine = audioEngine
    }
}
