import Foundation
import Darwin

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

        // 提示 libsystem_malloc 归还空闲 arena 页：Sherpa 峰值占用 600MB+，free 后这些脏页不会自动返还 OS。
        // 实测在 Sequoia 上只能回收约 16KB（残留主要是 ONNX runtime 的 C++ 静态全局，dlclose 后仍驻留），保留这行
        // 是因为开销几毫秒且无副作用，未来 macOS 改善时可能起效。彻底释放残留 RSS 需要把 Sherpa 子进程化。
        // (Hint libsystem_malloc to return free arena pages. Empirically only reclaims ~16KB on Sequoia — most of
        //  the residual RSS is ONNX runtime's static C++ globals that dlclose can't tear down. Kept anyway: harmless,
        //  cheap, and may help on future macOS. Full reclamation requires moving Sherpa into a subprocess.)
        _ = malloc_zone_pressure_relief(nil, 0)
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
