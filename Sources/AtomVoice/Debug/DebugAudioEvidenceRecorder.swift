#if DEBUG_BUILD
import AVFoundation
import Foundation

enum DebugAudioEvidenceReason: String {
    case sessionStartFailed = "session-start-failed"
    case audioRouteRecoveryFailed = "audio-route-recovery-failed"
}

/// Debug 构建中保留最近一段输入音频，失败时落盘为 CAF，便于复盘真实输入状态。
final class DebugAudioEvidenceRecorder {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AtomVoice/AudioEvidence", isDirectory: true)
    }

    private let directory: URL
    private let maxDuration: TimeInterval
    private let maxFiles: Int
    private let clock: () -> Date
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var formatFingerprint: String?

    init(
        directory: URL = DebugAudioEvidenceRecorder.defaultDirectory,
        maxDuration: TimeInterval = 12,
        maxFiles: Int = 12,
        clock: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxDuration = max(1, maxDuration)
        self.maxFiles = max(1, maxFiles)
        self.clock = clock
    }

    func reset() {
        lock.lock()
        buffers.removeAll()
        totalFrames = 0
        formatFingerprint = nil
        lock.unlock()
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        let fingerprint = Self.fingerprint(for: buffer.format)
        if let formatFingerprint, formatFingerprint != fingerprint {
            buffers.removeAll()
            totalFrames = 0
        }
        formatFingerprint = fingerprint
        buffers.append(buffer)
        totalFrames += AVAudioFramePosition(buffer.frameLength)
        trimLocked()
        lock.unlock()
    }

    @discardableResult
    func preserve(reason: DebugAudioEvidenceReason) -> URL? {
        let snapshot = makeSnapshot()
        guard !snapshot.buffers.isEmpty, let format = snapshot.format else {
            DebugLog.info("[AudioEvidence] No recent audio buffers to preserve reason=\(reason.rawValue)")
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = makeFileURL(reason: reason)
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            for buffer in snapshot.buffers {
                try file.write(from: buffer)
            }
            pruneOldFiles()
            DebugLog.info(
                "[AudioEvidence] Preserved \(snapshot.frames) frames reason=\(reason.rawValue) path=\(fileURL.path)"
            )
            return fileURL
        } catch {
            DebugLog.error("[AudioEvidence] Failed to preserve audio reason=\(reason.rawValue) error=\(error)")
            return nil
        }
    }

    private func makeSnapshot() -> (buffers: [AVAudioPCMBuffer], format: AVAudioFormat?, frames: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, buffers.last?.format, totalFrames)
    }

    private func trimLocked() {
        guard let sampleRate = buffers.last?.format.sampleRate, sampleRate > 0 else { return }
        let maxFrames = AVAudioFramePosition(maxDuration * sampleRate)
        while totalFrames > maxFrames, let first = buffers.first {
            totalFrames -= AVAudioFramePosition(first.frameLength)
            buffers.removeFirst()
        }
    }

    private func makeFileURL(reason: DebugAudioEvidenceReason) -> URL {
        let timestamp = Self.timestampFormatter.string(from: clock())
        let suffix = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent(
            "AtomVoice-audio-\(timestamp)-\(reason.rawValue)-\(suffix).caf"
        )
    }

    private func pruneOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let evidenceFiles = files.filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix("AtomVoice-audio-") }
        guard evidenceFiles.count > maxFiles else { return }

        let sorted = evidenceFiles.sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }
        for url in sorted.dropFirst(maxFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func fingerprint(for format: AVAudioFormat) -> String {
        [
            "\(format.commonFormat.rawValue)",
            "\(format.sampleRate)",
            "\(format.channelCount)",
            format.isInterleaved ? "interleaved" : "planar",
        ].joined(separator: ":")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
#endif
