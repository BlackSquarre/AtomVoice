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

    private let requestLock = NSLock()
    private var generation = 0
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
        let newRequest = recognizer.start(
            onResult: onResult,
            onError: onError,
            onRequestSwitch: { [weak self] newRequest in
                self?.setRequest(newRequest)
            }
        )
        setRequest(newRequest)
        return nil
    }

    func accept(buffer: AVAudioPCMBuffer) {
        audioConsumer()(buffer)
    }

    private func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock()
        self.request = request
        requestLock.unlock()
    }

    func audioConsumer() -> (AVAudioPCMBuffer) -> Void {
        requestLock.lock()
        let token = generation
        requestLock.unlock()
        return { [self] buffer in
            requestLock.lock()
            let destination = generation == token ? request : nil
            requestLock.unlock()
            destination?.append(buffer)
        }
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        completion(stopSynchronously(), nil)
    }

    @discardableResult
    func stopSynchronously() -> String {
        let text = recognizer.stop()
        requestLock.lock()
        request = nil
        generation += 1
        requestLock.unlock()
        return text
    }

    func cancel() {
        _ = stopSynchronously()
    }
}

/// 串行执行器只依赖运行时操作，测试使用 fake，避免加载真实模型。
protocol SherpaRecognitionRuntime: AnyObject {
    var currentText: String { get }
    var isModelLoaded: Bool { get }
    var lastStartFailureKind: SherpaOnnxStartFailureKind? { get }
    func start(onResult: @escaping (String, Bool) -> Void) -> String?
    func accept(buffer: AVAudioPCMBuffer)
    func stop() -> String
    func invalidatePendingAudio()
    func cancel()
    func releaseModels()
    func punctuate(_ text: String) -> String?
}

extension SherpaOnnxRecognizerController: SherpaRecognitionRuntime {}

final class SherpaOnnxASREngine: ASREngine {
    let descriptor = ASREngineDescriptor.sherpaOnnx
    private let operations = DispatchQueue(label: "com.atomvoice.sherpa.operations", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation = 0
    let recognizer: any SherpaRecognitionRuntime

    init(recognizer: any SherpaRecognitionRuntime = SherpaOnnxRecognizerController()) {
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

    func startAsync(onResult: @escaping (String, Bool) -> Void, completion: @escaping (String?) -> Void) {
        let token = currentGeneration
        operations.async { [self] in
            guard currentGeneration == token else { return }
            let error = recognizer.start(onResult: onResult)
            DispatchQueue.main.async { [self] in
                guard currentGeneration == token else { return }
                completion(error)
            }
        }
    }

    private var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    func audioConsumer() -> (AVAudioPCMBuffer) -> Void {
        let token = currentGeneration
        return { [self] buffer in
            guard currentGeneration == token else { return }
            // RecordingAudioInput 已在自己的串行队列中交接并持有 buffer；
            // 识别器内部还有独立串行队列，这里无需再包一层每帧 async。
            recognizer.accept(buffer: buffer)
        }
    }

    func accept(buffer: AVAudioPCMBuffer) {
        audioConsumer()(buffer)
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        let token = currentGeneration
        operations.async { [self] in
            guard currentGeneration == token else { return }
            let text = recognizer.stop()
            DispatchQueue.main.async { [self] in
                guard currentGeneration == token else { return }
                completion(text, nil)
            }
        }
    }

    @discardableResult
    func stopSynchronously() -> String {
        recognizer.stop()
    }

    func cancel() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
        recognizer.invalidatePendingAudio()
        operations.async { [self] in recognizer.cancel() }
    }

    func releaseModels() {
        operations.async { [self] in recognizer.releaseModels() }
    }

    func punctuateAsync(_ text: String, completion: @escaping (String?) -> Void) {
        let token = currentGeneration
        operations.async { [self] in
            let result = currentGeneration == token ? recognizer.punctuate(text) : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    func punctuate(_ text: String) -> String? {
        recognizer.punctuate(text)
    }
}

final class VolcengineASREngine: ASREngine {
    let descriptor = ASREngineDescriptor.volcengine
    private let preparationQueue = DispatchQueue(label: "com.atomvoice.cloud.prepare", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation = 0
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

    func startAsync(onResult: @escaping (String, Bool) -> Void,
                    onError: @escaping (String) -> Void,
                    completion: @escaping (String?) -> Void) {
        let token = currentGeneration
        preparationQueue.async { [self] in
            guard currentGeneration == token else { return }
            let error = recognizer.start(onResult: onResult, onError: onError)
            DispatchQueue.main.async { [self] in
                guard currentGeneration == token else { return }
                completion(error)
            }
        }
    }

    private var currentGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    func audioConsumer() -> (AVAudioPCMBuffer) -> Void {
        let token = currentGeneration
        return { [self] buffer in
            guard currentGeneration == token else { return }
            // CloudASRRecognizerController 自己负责串行化转换和发送。
            recognizer.accept(buffer: buffer)
        }
    }

    func accept(buffer: AVAudioPCMBuffer) {
        audioConsumer()(buffer)
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        let token = currentGeneration
        preparationQueue.async { [self] in
            guard currentGeneration == token else { return }
            recognizer.stop(completion: completion)
        }
    }

    func cancel() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
        preparationQueue.async { [self] in recognizer.cancel() }
    }
}
