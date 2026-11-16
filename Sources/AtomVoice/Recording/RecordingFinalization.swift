import Foundation

/// 停录后的结果归属于原轮次；识别资源屏障和后处理输出有效性彼此独立。
final class RecordingFinalization {
    let generation: Int
    let audioInput: RecordingAudioInput
    let resources: Set<String>
    var engineCode: String
    let liveInsertion: RecognitionLiveInsertionSnapshot
    let streamSession: TextStreamSession?
    private(set) var settings: RecognitionResultFinalizer.Settings
    private(set) var settingsReady: Bool
    let outputSink: TextOutputSink
    private(set) var isOutputValid = true
    private(set) var isRecognitionPending = true
    private var recognitionWaiters: [() -> Void] = []
    private var settingsWaiter: (() -> Void)?

    init(generation: Int, audioInput: RecordingAudioInput, resources: Set<String>, engineCode: String,
         liveInsertion: RecognitionLiveInsertionSnapshot, streamSession: TextStreamSession?,
         settings: RecognitionResultFinalizer.Settings, outputSink: TextOutputSink,
         settingsReady: Bool = true) {
        self.generation = generation
        self.audioInput = audioInput
        self.resources = resources
        self.engineCode = engineCode
        self.liveInsertion = liveInsertion
        self.streamSession = streamSession
        self.settings = settings
        self.settingsReady = settingsReady
        self.outputSink = outputSink
    }

    /// 只等待本轮配置，不占用已经释放的识别资源。
    func whenSettingsReady(_ completion: @escaping () -> Void) {
        guard isOutputValid else { return }
        if settingsReady { completion() }
        else { settingsWaiter = completion }
    }

    func completeSettings(_ settings: RecognitionResultFinalizer.Settings) {
        guard isOutputValid, !settingsReady else { return }
        self.settings = settings
        settingsReady = true
        let completion = settingsWaiter
        settingsWaiter = nil
        completion?()
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
        settingsWaiter = nil
        releaseRecognitionWaiters()
    }
}
