import AVFoundation

/// 每轮录音独占的交接缓冲。采集、回放和实时投递在同一队列排序，避免首帧交接乱序。
final class RecordingAudioInput {
    private let queue = DispatchQueue(label: "com.atomvoice.recordingInput", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var sealed = false
    private var cancelled = false
    private var buffers: [AVAudioPCMBuffer] = []
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var receivedFirstBuffer = false
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    func accept(_ buffer: AVAudioPCMBuffer) {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard !sealed, !cancelled,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, destination.count) {
            if let src = source[i].mData, let dst = destination[i].mData {
                memcpy(dst, src, Int(source[i].mDataByteSize))
            }
        }
        queue.async { [self] in
            guard !isCancelled else { return }
            if !receivedFirstBuffer {
                receivedFirstBuffer = true
                DebugLog.info("[RecordingLatency] first audio buffer ms=\((ProcessInfo.processInfo.systemUptime - createdAt) * 1000)")
            }
            if let handler { handler(copy) } else { buffers.append(copy) }
        }
    }

    /// 历史快照也在输入队列内取得；回放期间进入的新帧排在同一个交接块之后。
    func connect(replaying history: (() -> [AVAudioPCMBuffer])? = nil,
                 _ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            guard !isCancelled else { return }
            let replay = history?() ?? []
            self.handler = handler
            let pending = buffers
            buffers.removeAll()
            for buffer in replay {
                guard !isCancelled else { break }
                handler(buffer)
            }
            for buffer in pending {
                guard !isCancelled else { break }
                handler(buffer)
            }
        }
    }

    /// 松键后禁止新帧进入，但保留已录音频，允许识别器稍后接入。
    func seal() {
        admissionLock.lock()
        sealed = true
        admissionLock.unlock()
    }

    /// 在已接入识别器、已封口的前提下，等所有音频投递完再提交停止命令。
    func finish(_ completion: @escaping () -> Void) {
        seal()
        queue.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    func cancel() {
        admissionLock.lock()
        cancelled = true
        sealed = true
        admissionLock.unlock()
        queue.async { [self] in
            buffers.removeAll()
            handler = nil
        }
    }

    private var isCancelled: Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        return cancelled
    }
}
