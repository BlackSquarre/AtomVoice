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
        clearAudioBuffers()
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
        if isFirstResult { clearAudioBuffers() }
        return isFirstResult
    }

    func appendAudioBufferIfWaiting(_ buffer: AVAudioPCMBuffer,
                                    copyBuffer: (AVAudioPCMBuffer) -> AVAudioPCMBuffer?) {
        guard withLock({ waitingForFirstResult }) else { return }
        guard let copiedBuffer = copyBuffer(buffer) else { return }
        audioQueue.async { [weak self] in
            self?.audioBuffers.append(copiedBuffer)
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
        clearAudioBuffers()
    }

    func makeFallbackSnapshot(originalError: String,
                              fallbackTextIfAppleEmpty: String = "",
                              stopLiveFallback: () -> String) -> Snapshot {
        let buffers = snapshotAudioBuffers()
        clearAudioBuffers()

        let state = withLock { () -> (String, Bool) in
            errorMessage = nil
            waitingForFirstResult = false

            let cloudPrefixText = fallbackTextIfAppleEmpty.isEmpty ? prefixText : fallbackTextIfAppleEmpty
            prefixText = ""

            let shouldStopAppleLiveFallback = appleLiveActive
            appleLiveActive = false
            return (cloudPrefixText, shouldStopAppleLiveFallback)
        }

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
        clearAudioBuffers()
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

    private func snapshotAudioBuffers() -> [AVAudioPCMBuffer] {
        audioQueue.sync { audioBuffers }
    }

    private func clearAudioBuffers() {
        audioQueue.sync {
            audioBuffers.removeAll(keepingCapacity: false)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
