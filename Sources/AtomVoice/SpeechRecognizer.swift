import Speech
import AVFoundation

final class SpeechRecognizerController {
    private var recognizer: SFSpeechRecognizer?
    private(set) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // 分段续录
    private var segmentOffset: String = ""     // 已完成分段的累积文字
    private var currentSegmentText: String = "" // 当前分段的最新识别文字
    private var activeTaskID: Int = 0          // 用于让旧任务回调失效
    private var rollingTimer: Timer?
    private let rollingInterval: TimeInterval = 50  // 每 50s 滚动一次，留 10s 余量

    // 回调
    private var onResult: ((String, Bool) -> Void)?
    private var onRequestSwitch: ((SFSpeechAudioBufferRecognitionRequest) -> Void)?

    init() {
        updateLanguage()
    }

    func updateLanguage() {
        let langCode = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: langCode))
        recognizer?.defaultTaskHint = .dictation
    }

    // MARK: - 开始识别

    /// 返回首个识别请求（供 AudioEngine 推送 buffer）
    func start(
        onResult: @escaping (String, Bool) -> Void,
        onRequestSwitch: @escaping (SFSpeechAudioBufferRecognitionRequest) -> Void
    ) -> SFSpeechAudioBufferRecognitionRequest? {
        self.onResult = onResult
        self.onRequestSwitch = onRequestSwitch
        segmentOffset = ""
        currentSegmentText = ""
        activeTaskID = 0

        let request = makeRequest()
        recognitionRequest = request
        startTask(request: request, taskID: 0)
        scheduleRollingTimer()
        return request
    }

    // MARK: - 停止识别

    func stop() -> String {
        rollingTimer?.invalidate()
        rollingTimer = nil

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        onResult = nil
        onRequestSwitch = nil

        return segmentOffset + currentSegmentText
    }

    // MARK: - 滚动分段

    private func scheduleRollingTimer() {
        rollingTimer?.invalidate()
        rollingTimer = Timer.scheduledTimer(
            withTimeInterval: rollingInterval,
            repeats: false
        ) { [weak self] _ in
            self?.roll()
        }
    }

    private func roll() {
        guard let recognizer, recognizer.isAvailable,
              let oldRequest = recognitionRequest else { return }

        // 1. 提交当前分段文字到 offset
        segmentOffset += currentSegmentText
        currentSegmentText = ""

        // 2. 让旧任务的后续回调失效
        activeTaskID += 1
        let newTaskID = activeTaskID

        // 3. 新建请求，通知 AudioEngine 切流
        let newRequest = makeRequest()
        recognitionRequest = newRequest
        onRequestSwitch?(newRequest)

        // 4. 结束旧请求的音频（旧任务自行收尾，回调因 taskID 不匹配而被忽略）
        oldRequest.endAudio()

        // 5. 启动新任务
        startTask(request: newRequest, taskID: newTaskID)

        // 6. 重置计时器
        scheduleRollingTimer()
    }

    // MARK: - 私有辅助

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        return req
    }

    private func startTask(request: SFSpeechAudioBufferRecognitionRequest, taskID: Int) {
        guard let recognizer else { return }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, taskID == self.activeTaskID else { return }

            if let result {
                self.currentSegmentText = result.bestTranscription.formattedString
                let fullText = self.segmentOffset + self.currentSegmentText
                self.onResult?(fullText, result.isFinal)
            }
            if let error {
                let nsError = error as NSError
                // 216 = 用户取消，属正常流程，不打印
                if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                    print("[SpeechRecognizer] Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
