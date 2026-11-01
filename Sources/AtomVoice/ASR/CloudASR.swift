import Accelerate
import AVFoundation
import Foundation

/// 云端层保留分类与显示文案；恢复决策不再在多个调用方重复解析文案。
struct CloudASRFailure {
    enum Kind { case transport, server, protocolMessage, timeout }
    let kind: Kind
    let message: String
    let isBenignSocketClosure: Bool

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
        // 沿用既有兼容匹配，不扩大静默错误范围。
        let lowercased = message.lowercased()
        isBenignSocketClosure = lowercased.contains("socket") && (
            lowercased.contains("not connected") || lowercased.contains("未连接") || lowercased.contains("未能完成"))
    }
}

/// PCM16 mono 的传输参数由服务商给出，时长保留现有默认值。
struct CloudASRAudioConfiguration {
    var sampleRate: Double = 16_000
    var lowLatencyChunkDuration: Double = 0.1
    var standardChunkDuration: Double = 0.2
    var lowLatencyWindow: Double = 1
    var minimumUsefulDuration: Double = 0.25
    var connectionTimeout: Double = 2

    var consumerFormat: AudioRouter.ConsumerFormat { .init(sampleRate: sampleRate, channelCount: 1) }
    func byteCount(duration: Double) -> Int { Int(sampleRate * duration) * MemoryLayout<Int16>.size }
}

// MARK: - 通用云端 ASR 协议（Common cloud ASR protocols）

/// 云端 ASR 连接代理（Cloud ASR connection delegate）
protocol CloudASRConnectionDelegate: AnyObject {
    func connectionDidOpen(_ connection: CloudASRConnection)
    func connection(_ connection: CloudASRConnection, didReceiveText text: String, isFinal: Bool)
    func connection(_ connection: CloudASRConnection, didFailWithError error: CloudASRFailure)
}

/// 云端 ASR 连接（Cloud ASR connection）
///
/// 生命周期：connect → onReady → sendAudioChunk 循环 → sendAudioChunk(isFinal) → 等待最终结果 / cancel
/// (Lifecycle: connect -> onReady -> sendAudioChunk loop -> sendAudioChunk(isFinal) -> wait for final result / cancel)
protocol CloudASRConnection: AnyObject {
    var delegate: CloudASRConnectionDelegate? { get set }
    func resume()
    func sendAudioChunk(_ data: Data, isFinal: Bool)
    func cancel()
}

/// 云端 ASR 服务提供商（Cloud ASR provider）
///
/// 每个厂商实现此协议，提供连接创建和凭据校验。
/// (Each vendor implements this protocol to create connections and validate credentials.)
protocol CloudASRProvider {
    var engineCode: String { get }
    var displayName: String { get }

    /// 校验凭据，返回错误信息；nil 表示通过（Validate credentials; returns an error message, or nil on success）
    func validateCredentials() -> String?

    /// 创建新连接；返回 nil 表示无法创建（Create a new connection; nil means creation failed）
    func createConnection() -> CloudASRConnection?

    var audioConfiguration: CloudASRAudioConfiguration { get }

    /// 最终结果等待超时（秒）（Final-result wait timeout in seconds）
    var finalResultTimeout: Double { get }
}

extension CloudASRProvider {
    var audioConfiguration: CloudASRAudioConfiguration { .init() }
}

// MARK: - 通用音频转换器（PCM16 mono，采样率由配置声明）

/// 通用云端 ASR 音频转换器：按服务商配置转为 mono pcm_s16le。
final class CloudAudioConverter {
    private let outputFormat: AVAudioFormat

    init(sampleRate: Double = 16_000) {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: 1, interleaved: false)!
    }
    private var converter: AVAudioConverter?
    private var inputFormatDescription = ""

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format
        if inputFormat.sampleRate == outputFormat.sampleRate,
           inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32,
           !inputFormat.isInterleaved,
           let channelData = buffer.floatChannelData {
            return convertFloat32ToPCM16(channelData[0], frameCount: Int(buffer.frameLength))
        }
        let description = "\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.commonFormat.rawValue)-\(inputFormat.isInterleaved)"
        if converter == nil || description != inputFormatDescription {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            inputFormatDescription = description
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else {
            return nil
        }

        var didProvideInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error, let channelData = outputBuffer.floatChannelData else {
            if let error {
                DebugLog.error("[CloudASR] audio convert failed: \(error.localizedDescription)")
            }
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        // 用 vDSP 做 Float32 → Int16 的向量化转换：
        //   1. clip 到 [-1, 1] 防止过载样本溢出 Int16 范围
        //   2. 乘以 Int16.max 缩放到整型范围
        //   3. vDSP_vfix16 一次性写入小端 Int16（macOS 是 little-endian，与火山协议要求一致）
        // (Vectorize Float32 → Int16 PCM via Accelerate; replaces a per-sample loop.)
        let floatPtr = channelData[0]
        var lower: Float = -1.0
        var upper: Float = 1.0
        vDSP_vclip(floatPtr, 1, &lower, &upper, floatPtr, 1, vDSP_Length(frameCount))

        var scale: Float = Float(Int16.max)
        vDSP_vsmul(floatPtr, 1, &scale, floatPtr, 1, vDSP_Length(frameCount))

        var data = Data(count: frameCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            vDSP_vfix16(floatPtr, 1, dst, 1, vDSP_Length(frameCount))
        }
        return data
    }

    private func convertFloat32ToPCM16(_ source: UnsafePointer<Float>, frameCount: Int) -> Data? {
        guard frameCount > 0 else { return nil }
        var clipped = [Float](repeating: 0, count: frameCount)
        clipped.withUnsafeMutableBufferPointer { destination in
            var lower: Float = -1.0
            var upper: Float = 1.0
            vDSP_vclip(source, 1, &lower, &upper, destination.baseAddress!, 1, vDSP_Length(frameCount))
            var scale: Float = Float(Int16.max)
            vDSP_vsmul(destination.baseAddress!, 1, &scale, destination.baseAddress!, 1, vDSP_Length(frameCount))
        }
        var data = Data(count: frameCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            clipped.withUnsafeBufferPointer { values in
                vDSP_vfix16(values.baseAddress!, 1, dst, 1, vDSP_Length(frameCount))
            }
        }
        return data
    }
}

// MARK: - 通用云端 ASR 识别控制器（Common cloud ASR recognizer controller）

/// 通用云端 ASR 识别控制器，管理状态机、音频缓冲和连接生命周期
/// (Cloud ASR recognizer controller: manages state machine, audio buffer, and connection lifecycle)
final class CloudASRRecognizerController: NSObject {
    private enum State {
        case idle
        case connecting
        case streaming
        case finishing
        case cancelled
    }

    private let provider: CloudASRProvider
    private let queue = DispatchQueue(label: "com.atomvoice.cloudASR")
    private let audioConfiguration: CloudASRAudioConfiguration
    private var lowLatencyChunkSizeBytes: Int { audioConfiguration.byteCount(duration: audioConfiguration.lowLatencyChunkDuration) }
    private var standardChunkSizeBytes: Int { audioConfiguration.byteCount(duration: audioConfiguration.standardChunkDuration) }
    private var lowLatencyWindowBytes: Int { audioConfiguration.byteCount(duration: audioConfiguration.lowLatencyWindow) }
    private var minimumUsefulAudioBytes: Int { audioConfiguration.byteCount(duration: audioConfiguration.minimumUsefulDuration) }
    var preferredAudioFormat: AudioRouter.ConsumerFormat { audioConfiguration.consumerFormat }

    private var connection: CloudASRConnection?
    private var converter: CloudAudioConverter
    private var chunkBuffer = Data()
    private var state: State = .idle
    private var finishAfterConnect = false
    private let textLock = NSLock()
    private var textSnapshot = ""
    private var lastText = "" {
        didSet {
            textLock.lock()
            textSnapshot = lastText
            textLock.unlock()
        }
    }
    private var finishCompletion: ((String, String?) -> Void)?
    private var onResult: ((String, Bool) -> Void)?
    private var onError: ((CloudASRFailure) -> Void)?
    private var sentAudioBytes = 0
    private var sessionID = 0

    init(provider: CloudASRProvider) {
        self.provider = provider
        audioConfiguration = provider.audioConfiguration
        converter = CloudAudioConverter(sampleRate: audioConfiguration.sampleRate)
    }

    var currentText: String {
        textLock.lock(); defer { textLock.unlock() }
        return textSnapshot
    }

    var engineCode: String { provider.engineCode }

    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (CloudASRFailure) -> Void) -> String? {
        if let error = provider.validateCredentials() {
            DebugLog.error("[CloudASR] Credential validation failed: \(error)")
            return error
        }
        guard let connection = provider.createConnection() else {
            DebugLog.error("[CloudASR] Failed to create connection")
            return loc("cloudASR.error.noConnection")
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked()
            self.sessionID += 1
            let sessionID = self.sessionID
            self.connection = connection
            self.converter = CloudAudioConverter(sampleRate: self.audioConfiguration.sampleRate)
            self.chunkBuffer = Data()
            self.state = .connecting
            self.finishAfterConnect = false
            self.lastText = ""
            self.finishCompletion = nil
            self.onResult = onResult
            self.onError = onError
            self.sentAudioBytes = 0

            DebugLog.info("[CloudASR] Starting connection, sessionID=\(sessionID)")

            connection.delegate = self
            connection.resume()

            // 连接超时（Connection timeout）
            self.queue.asyncAfter(deadline: .now() + self.audioConfiguration.connectionTimeout) { [weak self] in
                guard let self,
                      self.sessionID == sessionID,
                      self.connection === connection,
                      self.state == .connecting
                else { return }
                DebugLog.error("[CloudASR] Connection timed out (\(self.audioConfiguration.connectionTimeout)s), sessionID=\(sessionID)")
                self.failLocked(.init(kind: .timeout, message: loc("cloudASR.error.connectionFailed", loc("cloudASR.error.timeout"))))
            }
        }

        return nil
    }

    func accept(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, self.state == .connecting || self.state == .streaming else { return }
            guard let pcm = self.converter.convert(buffer), !pcm.isEmpty else { return }
            self.chunkBuffer.append(pcm)

            if self.state == .streaming {
                self.flushBufferedAudioLocked()
            }
        }
    }

    func stop(completion: @escaping (String, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.state == .connecting {
                self.finishCompletion = completion
                self.finishAfterConnect = true
                return
            }
            guard self.state == .streaming else {
                let text = self.lastText
                DispatchQueue.main.async { completion(text, nil) }
                return
            }

            self.finishCompletion = completion
            self.beginFinishingLocked()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.cancelLocked()
        }
    }

    // MARK: - 内部方法（Internal methods）

    private func flushBufferedAudioLocked() {
        while chunkBuffer.count >= currentChunkSizeBytesLocked() {
            let chunkSize = currentChunkSizeBytesLocked()
            let chunk = chunkBuffer.prefix(chunkSize)
            chunkBuffer.removeFirst(chunkSize)
            connection?.sendAudioChunk(Data(chunk), isFinal: false)
            sentAudioBytes += chunkSize
        }
    }

    private func currentChunkSizeBytesLocked() -> Int {
        sentAudioBytes < lowLatencyWindowBytes ? lowLatencyChunkSizeBytes : standardChunkSizeBytes
    }

    private func beginFinishingLocked() {
        state = .finishing
        finishAfterConnect = false

        // 极短点按可能还没有任何音频进来，直接结束，避免向刚关闭的 WebSocket 发送空 final 帧。
        // (Very short taps may have no audio yet; finish directly instead of sending an empty final frame.)
        guard !chunkBuffer.isEmpty || sentAudioBytes > 0 else {
            completeStopLocked(text: lastText, error: nil)
            return
        }

        // 发送剩余缓冲音频（Send remaining buffered audio）
        while chunkBuffer.count >= currentChunkSizeBytesLocked() {
            let chunkSize = currentChunkSizeBytesLocked()
            let chunk = chunkBuffer.prefix(chunkSize)
            chunkBuffer.removeFirst(chunkSize)
            connection?.sendAudioChunk(Data(chunk), isFinal: false)
            sentAudioBytes += chunkSize
        }
        connection?.sendAudioChunk(chunkBuffer, isFinal: true)
        sentAudioBytes += chunkBuffer.count
        chunkBuffer.removeAll()

        scheduleFinalTimeoutLocked()
    }

    private func scheduleFinalTimeoutLocked() {
        let timeout = provider.finalResultTimeout
        let sessionID = self.sessionID
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.sessionID == sessionID,
                  self.state == .finishing
            else { return }
            let text = self.lastText
            // 如果没有发送过音频且没有收到结果，不显示超时错误（If no audio was sent and no result received, don't show timeout error）
            let error: String? = (self.sentAudioBytes == 0 && text.isEmpty) ? nil : (text.isEmpty ? loc("cloudASR.error.timeout") : nil)
            self.completeStopLocked(text: text, error: error)
        }
    }

    private func failLocked(_ failure: CloudASRFailure) {
        let message = failure.message
        DebugLog.error("[CloudASR] Recognition failed: \(message), state=\(self.state), sentBytes=\(self.sentAudioBytes)")
        DebugLog.error("[CloudASR] error: \(message)")
        if state == .finishing || finishCompletion != nil {
            let audioBytes = sentAudioBytes + chunkBuffer.count
            let noUsefulRecognition = lastText.isEmpty && (
                audioBytes < minimumUsefulAudioBytes || failure.isBenignSocketClosure
            )
            completeStopLocked(text: lastText, error: noUsefulRecognition ? nil : (lastText.isEmpty ? message : nil))
            return
        }
        let callback = onError
        cancelLocked()
        DispatchQueue.main.async {
            callback?(failure)
        }
    }

    private func completeStopLocked(text: String, error: String?) {
        DebugLog.info("[CloudASR] Completed stop: text=\(text.prefix(50)), error=\(error ?? "nil"), sentBytes=\(self.sentAudioBytes)")
        let completion = finishCompletion
        DebugLog.info("[CloudASR] stop: bytes=\(self.sentAudioBytes)")
        finishCompletion = nil
        connection?.cancel()
        connection = nil
        state = .idle
        sessionID += 1
        finishAfterConnect = false
        onResult = nil
        onError = nil
        chunkBuffer.removeAll()
        DispatchQueue.main.async {
            completion?(text, error)
        }
    }

    private func cancelLocked() {
        sessionID += 1
        finishCompletion = nil
        connection?.cancel()
        connection = nil
        converter = CloudAudioConverter(sampleRate: audioConfiguration.sampleRate)
        chunkBuffer.removeAll()
        finishAfterConnect = false
        lastText = ""
        onResult = nil
        onError = nil
        state = .idle
    }
}

// MARK: - CloudASRConnectionDelegate

extension CloudASRRecognizerController: CloudASRConnectionDelegate {
    func connectionDidOpen(_ connection: CloudASRConnection) {
        queue.async { [weak self] in
            guard let self,
                  self.connection === connection,
                  self.state == .connecting
            else { return }

            DebugLog.info("[CloudASR] Connection opened, bufferedBytes=\(self.chunkBuffer.count)")

            self.state = .streaming

            if self.finishAfterConnect {
                self.beginFinishingLocked()
            } else {
                self.flushBufferedAudioLocked()
            }
        }
    }

    func connection(_ connection: CloudASRConnection, didReceiveText text: String, isFinal: Bool) {
        queue.async { [weak self] in
            guard let self,
                  self.connection === connection,
                  self.state != .idle, self.state != .cancelled
            else { return }

            ASRLatencyProbe.mark(text, stage: "cloud_receive", isFinal: isFinal)
            let shouldEmit = text != self.lastText || isFinal
            if shouldEmit {
                self.lastText = text
                ASRLatencyProbe.mark(text, stage: "cloud_emit_scheduled", isFinal: isFinal)
                DispatchQueue.main.async { [onResult] in
                    ASRLatencyProbe.mark(text, stage: "cloud_emit_main", isFinal: isFinal)
                    onResult?(text, isFinal)
                }
            } else {
                ASRLatencyProbe.mark(text, stage: "cloud_dedup_skip", isFinal: isFinal)
            }
            if isFinal, self.state == .finishing {
                self.completeStopLocked(text: self.lastText, error: nil)
            }
        }
    }

    func connection(_ connection: CloudASRConnection, didFailWithError error: CloudASRFailure) {
        DebugLog.error("[CloudASR] Connection error callback: \(error.message)")
        queue.async { [weak self] in
            guard let self,
                  self.connection === connection
            else { return }
            self.failLocked(error)
        }
    }


}
