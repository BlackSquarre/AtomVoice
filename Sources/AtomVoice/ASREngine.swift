import AVFoundation
import Speech

protocol ASREngine: AnyObject {
    var descriptor: ASREngineDescriptor { get }
    var currentText: String { get }

    func validate() -> String?
    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (String) -> Void) -> String?
    func accept(buffer: AVAudioPCMBuffer)
    func stop(completion: @escaping (String, String?) -> Void)
    func cancel()
}

extension ASREngine {
    func validate() -> String? { nil }
}

final class ASREngineRuntime {
    private let enginesByCode: [String: ASREngine]

    init(engines: [ASREngine]) {
        enginesByCode = Dictionary(uniqueKeysWithValues: engines.map { ($0.descriptor.code, $0) })
    }

    func engine(for code: String) -> ASREngine? {
        enginesByCode[code]
    }
}

final class AppleSpeechASREngine: ASREngine {
    let descriptor = ASREngineDescriptor.apple
    let recognizer: SpeechRecognizerController

    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(recognizer: SpeechRecognizerController = SpeechRecognizerController()) {
        self.recognizer = recognizer
    }

    var currentText: String {
        recognizer.currentText
    }

    func updateLanguage() {
        recognizer.updateLanguage()
    }

    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (String) -> Void) -> String? {
        request = recognizer.start(
            onResult: onResult,
            onRequestSwitch: { [weak self] newRequest in
                self?.request = newRequest
            }
        )
        return nil
    }

    func accept(buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        completion(stopSynchronously(), nil)
    }

    @discardableResult
    func stopSynchronously() -> String {
        let text = recognizer.stop()
        request = nil
        return text
    }

    func cancel() {
        _ = stopSynchronously()
    }
}

final class SherpaOnnxASREngine: ASREngine {
    let descriptor = ASREngineDescriptor.sherpaOnnx
    let recognizer: SherpaOnnxRecognizerController

    init(recognizer: SherpaOnnxRecognizerController = SherpaOnnxRecognizerController()) {
        self.recognizer = recognizer
    }

    var currentText: String {
        recognizer.currentText
    }

    var isModelLoaded: Bool {
        recognizer.isModelLoaded
    }

    var lastStartFailureKind: SherpaOnnxStartFailureKind? {
        recognizer.lastStartFailureKind
    }

    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (String) -> Void) -> String? {
        recognizer.start(onResult: onResult)
    }

    func accept(buffer: AVAudioPCMBuffer) {
        recognizer.accept(buffer: buffer)
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        completion(stopSynchronously(), nil)
    }

    @discardableResult
    func stopSynchronously() -> String {
        recognizer.stop()
    }

    func cancel() {
        _ = stopSynchronously()
    }

    func releaseModels() {
        recognizer.releaseModels()
    }

    func punctuate(_ text: String) -> String? {
        recognizer.punctuate(text)
    }
}

final class VolcengineASREngine: ASREngine {
    let descriptor = ASREngineDescriptor.volcengine
    let provider: VolcengineASRProvider
    let recognizer: CloudASRRecognizerController

    init(provider: VolcengineASRProvider = VolcengineASRProvider(),
         recognizer: CloudASRRecognizerController? = nil) {
        self.provider = provider
        self.recognizer = recognizer ?? CloudASRRecognizerController(provider: provider)
    }

    var currentText: String {
        recognizer.currentText
    }

    func validate() -> String? {
        provider.validateCredentials()
    }

    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (String) -> Void) -> String? {
        recognizer.start(onResult: onResult, onError: onError)
    }

    func accept(buffer: AVAudioPCMBuffer) {
        recognizer.accept(buffer: buffer)
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        recognizer.stop(completion: completion)
    }

    func cancel() {
        recognizer.cancel()
    }
}
