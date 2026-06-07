import AVFoundation
import Foundation

final class DoubaoFallbackCoordinator {
    struct Snapshot {
        let buffers: [AVAudioPCMBuffer]
        let cloudPrefixText: String
        let liveFallbackText: String
        let originalError: String
    }

    private let audioQueue = DispatchQueue(label: "com.atomvoice.doubaoFallbackAudio")
    private let lock = NSLock()

    private var audioBuffers: [AVAudioPCMBuffer] = []
    /// 全程维护的"最近 N 秒"滚动回看缓冲：豆包断流回退到 Apple 时，用它补回
    /// "豆包已收音但识别结果未回传"的交接缺口（云端流式有网络滞后，断流瞬间最后几秒往往丢字）。
    /// (Rolling N-second look-back buffer kept for the whole session; bridges the hand-off gap when
    ///  falling back to Apple — cloud streaming lags, so the last seconds before a disconnect are
    ///  otherwise lost.)
    private var rollingBuffers: [AVAudioPCMBuffer] = []
    private var rollingFrames: AVAudioFramePosition = 0
    /// 回看时长。取值在"覆盖断流缺口"与"控制与豆包前缀文本的重叠去重难度"之间折中。
    /// (Look-back window: balances covering the gap against the de-dup difficulty of the overlap
    ///  with Doubao's prefix text.)
    private let rollingLookbackDuration: TimeInterval = 5

    private var waitingForFirstResult = false
    private var errorMessage: String?
    private var appleLiveActive = false
    private var prefixText = ""

    var currentError: String? {
        withLock {
            guard let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return errorMessage
        }
    }

    var isAppleLiveActive: Bool {
        withLock { appleLiveActive }
    }

    func reset() {
        withLock {
            waitingForFirstResult = false
            errorMessage = nil
            appleLiveActive = false
            prefixText = ""
        }
        clearAllAudioBuffers()
    }

    func beginWaitingForFirstResult() {
        withLock { waitingForFirstResult = true }
    }

    @discardableResult
    func acceptCloudText(_ text: String) -> Bool {
        let isFirstResult = withLock {
            prefixText = text
            if waitingForFirstResult {
                waitingForFirstResult = false
                return true
            }
            return false
        }
        // 仅清等待期间的全量缓冲；滚动回看缓冲继续保留，供后续断流回退补缺口。
        // (Only the waiting-phase full buffer is cleared; the rolling look-back stays alive.)
        if isFirstResult { clearAudioBuffers() }
        return isFirstResult
    }

    /// 录音期间持续捕获音频。全程把音频追加进"最近 N 秒"滚动回看缓冲；在等待豆包首个结果期间，
    /// 额外保留全量音频（供"豆包全程无结果"的离线兜底）。两处共用同一份拷贝，避免重复拷贝。
    /// (Capture audio during recording. Always append to the rolling look-back buffer; while waiting
    ///  for Doubao's first result, also retain the full audio for the "no result at all" offline
    ///  fallback. Both share one copy.)
    func captureAudioBuffer(_ buffer: AVAudioPCMBuffer,
                            copyBuffer: (AVAudioPCMBuffer) -> AVAudioPCMBuffer?) {
        let keepFullAudio = withLock { waitingForFirstResult }
        guard let copiedBuffer = copyBuffer(buffer) else { return }
        audioQueue.async { [weak self] in
            guard let self else { return }
            if keepFullAudio {
                self.audioBuffers.append(copiedBuffer)
            }
            self.rollingBuffers.append(copiedBuffer)
            self.rollingFrames += AVAudioFramePosition(copiedBuffer.frameLength)
            self.trimRollingBuffers()
        }
    }

    @discardableResult
    func recordError(_ message: String, currentText: String) -> Bool {
        withLock {
            guard errorMessage == nil else { return false }
            errorMessage = message
            if prefixText.isEmpty {
                prefixText = currentText
            }
            waitingForFirstResult = false
            return true
        }
    }

    func beginAppleLiveFallback() -> String? {
        withLock {
            guard !appleLiveActive else { return nil }
            appleLiveActive = true
            return errorMessage
        }
    }

    func liveDisplayText(liveText: String = "") -> String {
        let prefix = withLock { prefixText }
        return Self.combinedText(prefix: prefix, cachedText: "", liveText: liveText)
    }

    func finishSuccessfulCloudRecognition() {
        withLock {
            waitingForFirstResult = false
            errorMessage = nil
            appleLiveActive = false
            prefixText = ""
        }
        clearAllAudioBuffers()
    }

    func makeFallbackSnapshot(originalError: String,
                              fallbackTextIfAppleEmpty: String = "",
                              stopLiveFallback: () -> String) -> Snapshot {
        let fullBuffers = snapshotAudioBuffers()
        let rollingSnapshot = rollingBufferSnapshot()

        let state = withLock { () -> (String, Bool) in
            errorMessage = nil
            waitingForFirstResult = false

            let cloudPrefixText = fallbackTextIfAppleEmpty.isEmpty ? prefixText : fallbackTextIfAppleEmpty
            prefixText = ""

            let shouldStopAppleLiveFallback = appleLiveActive
            appleLiveActive = false
            return (cloudPrefixText, shouldStopAppleLiveFallback)
        }

        // 选定离线补识别用的音频：
        // - 已走实时回退：实时流（Apple Live）已接管并回灌过历史，无需再离线重识别
        // - 豆包全程无结果：用等待期间的全量音频离线识别
        // - 豆包出过字后断流：用最近 N 秒回看音频补回交接缺口（否则会丢断流瞬间的尾巴）
        // (Pick audio for offline re-recognition: live fallback already covers it; otherwise use the
        //  full waiting audio, or the rolling look-back to recover the tail lost at disconnect.)
        let buffers: [AVAudioPCMBuffer]
        if state.1 {
            buffers = []
        } else if !fullBuffers.isEmpty {
            buffers = fullBuffers
        } else {
            buffers = rollingSnapshot
        }
        clearAllAudioBuffers()

        let liveFallbackText = state.1 ? stopLiveFallback() : ""
        return Snapshot(
            buffers: buffers,
            cloudPrefixText: state.0,
            liveFallbackText: liveFallbackText,
            originalError: originalError
        )
    }

    func cancel() -> Bool {
        let shouldStopAppleLiveFallback = withLock { () -> Bool in
            waitingForFirstResult = false
            errorMessage = nil
            prefixText = ""
            let active = appleLiveActive
            appleLiveActive = false
            return active
        }
        clearAllAudioBuffers()
        return shouldStopAppleLiveFallback
    }

    static func combinedText(prefix: String, cachedText: String, liveText: String) -> String {
        var result = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        result = appendSegment(cachedText, to: result)
        result = appendSegment(liveText, to: result)
        return result
    }

    private static func appendSegment(_ segment: String, to base: String) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return base }
        guard !base.isEmpty else { return segment }

        if segment.hasPrefix(base) { return segment }
        if base.hasSuffix(segment) { return base }

        let maxOverlap = min(base.count, segment.count)
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if base.suffix(length) == segment.prefix(length) {
                return base + segment.dropFirst(length)
            }
        }

        let separator = shouldInsertSpaceBetweenSegments(base, segment) ? " " : ""
        return base + separator + segment
    }

    private static func shouldInsertSpaceBetweenSegments(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if PunctuationProcessor.isSentenceEndingPunctuation(last) { return true }
        return last.isASCII && first.isASCII && last.isLetter && first.isLetter
    }

    /// 取当前回看缓冲快照（最近 N 秒音频）。供回退到 Apple 时回灌补缺口。
    /// (Snapshot of the rolling look-back buffer; replayed into Apple on fallback to bridge the gap.)
    func rollingBufferSnapshot() -> [AVAudioPCMBuffer] {
        audioQueue.sync { rollingBuffers }
    }

    private func snapshotAudioBuffers() -> [AVAudioPCMBuffer] {
        audioQueue.sync { audioBuffers }
    }

    private func clearAudioBuffers() {
        audioQueue.sync {
            audioBuffers.removeAll(keepingCapacity: false)
        }
    }

    /// 清空全部捕获音频（全量 + 回看）。会话结束或快照取用后调用。
    /// (Clear all captured audio (full + look-back); called at session end or after snapshotting.)
    private func clearAllAudioBuffers() {
        audioQueue.sync {
            audioBuffers.removeAll(keepingCapacity: false)
            rollingBuffers.removeAll(keepingCapacity: false)
            rollingFrames = 0
        }
    }

    /// 在 audioQueue 上调用：裁掉超过回看时长的旧音频，维持滚动窗口。
    /// (Called on audioQueue: drop audio older than the look-back window to keep the rolling window.)
    private func trimRollingBuffers() {
        guard let sampleRate = rollingBuffers.last?.format.sampleRate, sampleRate > 0 else { return }
        let maxFrames = AVAudioFramePosition(rollingLookbackDuration * sampleRate)
        while rollingFrames > maxFrames, let first = rollingBuffers.first {
            rollingFrames -= AVAudioFramePosition(first.frameLength)
            rollingBuffers.removeFirst()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
