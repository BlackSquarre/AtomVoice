import AVFoundation
import Foundation
import os.log

private let cloudASRLogger = Logger(subsystem: "com.blacksquarre.AtomVoice", category: "CloudASR")

// MARK: - 通用云端 ASR 协议

/// 云端 ASR 连接代理（Cloud ASR connection delegate）
protocol CloudASRConnectionDelegate: AnyObject {
    func connectionDidOpen(_ connection: CloudASRConnection)
    func connection(_ connection: CloudASRConnection, didReceiveText text: String, isFinal: Bool)
    func connection(_ connection: CloudASRConnection, didFailWithError error: String)
}

/// 云端 ASR 连接（Cloud ASR connection）
///
/// 生命周期：connect → onReady → sendAudioChunk 循环 → sendAudioChunk(isFinal) → 等待最终结果 / cancel
protocol CloudASRConnection: AnyObject {
    var delegate: CloudASRConnectionDelegate? { get set }
    func resume()
    func sendAudioChunk(_ data: Data, isFinal: Bool)
    func cancel()
}

/// 云端 ASR 服务提供商（Cloud ASR provider）
///
/// 每个厂商实现此协议，提供连接创建和凭据校验。
protocol CloudASRProvider {
    var engineCode: String { get }
    var displayName: String { get }

    /// 校验凭据，返回错误信息；nil 表示通过
    func validateCredentials() -> String?

    /// 创建新连接；返回 nil 表示无法创建
    func createConnection() -> CloudASRConnection?

    /// 打开设置窗口
    func showSettings()

    /// 最终结果等待超时（秒）
    var finalResultTimeout: Double { get }
}

// MARK: - 通用音频转换器（16kHz mono pcm_s16le）

/// 通用云端 ASR 音频转换器：将 AVAudioPCMBuffer 转为 16kHz mono pcm_s16le
/// (Cloud audio converter: converts AVAudioPCMBuffer to 16kHz mono pcm_s16le)
final class CloudAudioConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var inputFormatDescription = ""

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format
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
                cloudASRLogger.error("[audio] convert failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * Float(Int16.max))
            data.append(UInt8(truncatingIfNeeded: intSample))
            data.append(UInt8(truncatingIfNeeded: intSample >> 8))
        }
        return data
    }
}

// MARK: - 通用云端 ASR 识别控制器

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
    private let chunkSizeBytes = 16_000 / 5 * 2  // 200ms, mono, int16
    private let minimumUsefulAudioBytes = 16_000 / 4 * 2  // 250ms, mono, int16

    private var connection: CloudASRConnection?
    private var converter = CloudAudioConverter()
    private var chunkBuffer = Data()
    private var state: State = .idle
    private var finishAfterConnect = false
    private var lastText = ""
    private var finishCompletion: ((String, String?) -> Void)?
    private var onResult: ((String, Bool) -> Void)?
    private var onError: ((String) -> Void)?
    private var sentAudioBytes = 0
    private var sessionID = 0

    init(provider: CloudASRProvider) {
        self.provider = provider
    }

    var currentText: String {
        queue.sync { lastText }
    }

    var engineCode: String { provider.engineCode }

    func start(onResult: @escaping (String, Bool) -> Void,
               onError: @escaping (String) -> Void) -> String? {
        if let error = provider.validateCredentials() { return error }
        guard let connection = provider.createConnection() else {
            return loc("cloudASR.error.noConnection")
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked()
            self.sessionID += 1
            let sessionID = self.sessionID
            self.connection = connection
            self.converter = CloudAudioConverter()
            self.chunkBuffer = Data()
            self.state = .connecting
            self.finishAfterConnect = false
            self.lastText = ""
            self.finishCompletion = nil
            self.onResult = onResult
            self.onError = onError
            self.sentAudioBytes = 0

            connection.delegate = self
            connection.resume()

            // 连接超时（Connection timeout）
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self,
                      self.sessionID == sessionID,
                      self.connection === connection,
                      self.state == .connecting
                else { return }
                self.failLocked(loc("cloudASR.error.connectionFailed", loc("cloudASR.error.timeout")))
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

    // MARK: - 内部方法

    private func flushBufferedAudioLocked() {
        while chunkBuffer.count >= chunkSizeBytes {
            let chunk = chunkBuffer.prefix(chunkSizeBytes)
            chunkBuffer.removeFirst(chunkSizeBytes)
            connection?.sendAudioChunk(Data(chunk), isFinal: false)
            sentAudioBytes += chunkSizeBytes
        }
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
        while chunkBuffer.count >= chunkSizeBytes {
            let chunk = chunkBuffer.prefix(chunkSizeBytes)
            chunkBuffer.removeFirst(chunkSizeBytes)
            connection?.sendAudioChunk(Data(chunk), isFinal: false)
            sentAudioBytes += chunkSizeBytes
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

    private func failLocked(_ message: String) {
        cloudASRLogger.error("[error] \(message, privacy: .public)")
        if state == .finishing || finishCompletion != nil {
            let audioBytes = sentAudioBytes + chunkBuffer.count
            let tooShortForRecognition = lastText.isEmpty && audioBytes < minimumUsefulAudioBytes
            completeStopLocked(text: lastText, error: tooShortForRecognition ? nil : (lastText.isEmpty ? message : nil))
            return
        }
        let callback = onError
        cancelLocked()
        DispatchQueue.main.async {
            callback?(message)
        }
    }

    private func completeStopLocked(text: String, error: String?) {
        let completion = finishCompletion
        cloudASRLogger.info("[stop] bytes=\(self.sentAudioBytes, privacy: .public)")
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
        state = .cancelled
        sessionID += 1
        finishCompletion = nil
        connection?.cancel()
        connection = nil
        converter = CloudAudioConverter()
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

            #if DEBUG_BUILD
            cloudASRLogger.debug("[connectionDidOpen] bufferedBytes=\(self.chunkBuffer.count, privacy: .public)")
            #endif

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

            if text != self.lastText {
                self.lastText = text
                DispatchQueue.main.async { [onResult] in
                    onResult?(text, isFinal)
                }
            }
            if isFinal, self.state == .finishing {
                self.completeStopLocked(text: self.lastText, error: nil)
            }
        }
    }

    func connection(_ connection: CloudASRConnection, didFailWithError error: String) {
        queue.async { [weak self] in
            guard let self,
                  self.connection === connection
            else { return }
            self.failLocked(error)
        }
    }
}
