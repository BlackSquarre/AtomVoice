import Foundation

/// 停录后的结果归属于原轮次；识别资源屏障和后处理输出有效性彼此独立。
final class RecordingFinalization {
    let generation: Int
    let audioInput: RecordingAudioInput
    let resources: Set<String>
    var engineCode: String
    let liveInsertion: RecognitionLiveInsertionSnapshot
    let streamSession: TextStreamSession?
    let settings: RecognitionResultFinalizer.Settings
    let outputSink: TextOutputSink
    private(set) var isOutputValid = true
    private(set) var isRecognitionPending = true
    private var recognitionWaiters: [() -> Void] = []

    init(generation: Int, audioInput: RecordingAudioInput, resources: Set<String>, engineCode: String,
         liveInsertion: RecognitionLiveInsertionSnapshot, streamSession: TextStreamSession?,
         settings: RecognitionResultFinalizer.Settings, outputSink: TextOutputSink) {
        self.generation = generation
        self.audioInput = audioInput
        self.resources = resources
        self.engineCode = engineCode
        self.liveInsertion = liveInsertion
        self.streamSession = streamSession
        self.settings = settings
        self.outputSink = outputSink
    }

    func whenRecognitionFinished(_ completion: @escaping () -> Void) {
        if isRecognitionPending { recognitionWaiters.append(completion) }
        else { completion() }
    }

    @discardableResult
    func completeRecognition() -> Bool {
        guard isRecognitionPending else { return false }
        isRecognitionPending = false
        return true
    }

    func releaseRecognitionWaiters() {
        let waiters = recognitionWaiters
        recognitionWaiters.removeAll()
        waiters.forEach { $0() }
    }

    func cancel() {
        isOutputValid = false
        isRecognitionPending = false
        releaseRecognitionWaiters()
    }
}
