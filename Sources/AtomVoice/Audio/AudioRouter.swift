import AVFoundation

/// 音频路由：把来自 AudioEngine tap 的单一 PCM 流，按各消费者声明的目标格式分发出去。
/// 各家 ASR 引擎、静音检测、FFT 等通过 register 订阅自己想要的 SR/通道数；
/// router 内部缓存 AVAudioConverter，按"目标 format key"分组复用，避免每帧多次重采样。
/// (Audio router: takes a single PCM stream from the AudioEngine tap and dispatches to consumers
///  at their declared target format. Converters are cached and shared across consumers with the
///  same target, so each unique target rate only resamples once per buffer.)
final class AudioRouter {
    /// 目标格式。nil 表示原生透传（拿到 inputNode 实际格式的 buffer）。
    /// (Target format. nil = passthrough at the engine's native input format.)
    struct ConsumerFormat: Hashable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount

        static let voice16k = ConsumerFormat(sampleRate: 16_000, channelCount: 1)

        fileprivate var avFormat: AVAudioFormat? {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            )
        }
    }

    typealias ConsumerHandler = (AVAudioPCMBuffer) -> Void

    private struct Consumer {
        let id: UUID
        let format: ConsumerFormat?
        let handler: ConsumerHandler
    }

    /// 一份 converter + 它的输出 format，按"输入 format 描述 + 目标 format"作为 key 缓存。
    /// (Cached converter keyed by input-format description + target format.)
    private struct ConverterEntry {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
    }

    private let consumerLock = NSLock()
    private let converterLock = NSLock()
    private var consumers: [Consumer] = []
    /// converter cache 的 key 把"输入 format 指纹"和"目标 format"拼起来，
    /// 输入 format 变化（如设备切换导致 SR 变化）时自动重建。
    /// (Cache key combines input-format fingerprint and target format; auto-rebuilds on input change.)
    private var converterCache: [String: ConverterEntry] = [:]
    private var converterCacheGeneration = 0

    func register(format: ConsumerFormat?, handler: @escaping ConsumerHandler) -> UUID {
        let consumer = Consumer(id: UUID(), format: format, handler: handler)
        consumerLock.lock(); defer { consumerLock.unlock() }
        consumers.append(consumer)
        return consumer.id
    }

    func unregister(_ id: UUID) {
        consumerLock.lock(); defer { consumerLock.unlock() }
        consumers.removeAll { $0.id == id }
    }

    /// 设备切换 / engine 重建后调用：input format 可能变化，丢掉所有缓存 converter 让下次按需重建。
    /// (Call after device/engine change to flush converters; next receive() rebuilds on demand.)
    func invalidate() {
        converterLock.lock(); defer { converterLock.unlock() }
        converterCache.removeAll(keepingCapacity: true)
        converterCacheGeneration &+= 1
    }

    /// 来自 AudioEngine tap 的单一回调。按消费者目标 format 分发；同一目标 format 多消费者共享一次转换。
    /// (Single entry point from the AudioEngine tap. Dispatch by target format; multiple consumers
    ///  with the same target share one conversion per buffer.)
    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let snapshot = consumerSnapshotForReceive() else { return }

        guard !snapshot.isEmpty else { return }

        // 按目标 format 分组：nil-format（原生）单独一组
        var nativeHandlers: [ConsumerHandler] = []
        var grouped: [ConsumerFormat: [ConsumerHandler]] = [:]
        for c in snapshot {
            if let fmt = c.format {
                grouped[fmt, default: []].append(c.handler)
            } else {
                nativeHandlers.append(c.handler)
            }
        }

        // 原生消费者：直接拿原 buffer
        for h in nativeHandlers { h(buffer) }

        // 目标格式消费者：每个目标 format 做一次转换，分发给该组所有消费者
        for (format, handlers) in grouped {
            guard let converted = convert(buffer, to: format) else { continue }
            for h in handlers { h(converted) }
        }
    }

    private func consumerSnapshotForReceive() -> [Consumer]? {
        // audio tap callback 不等待 register/unregister；锁忙时宁可丢弃当前帧。
        // (Do not block the audio tap on registration churn; drop this frame if the lock is busy.)
        guard consumerLock.try() else { return nil }
        defer { consumerLock.unlock() }
        return consumers
    }

    // MARK: - 内部转换

    /// 输入 format 的"指纹"用于 cache key（SR/声道/format/interleaved 任何一项变化都要重建 converter）。
    private func inputFingerprint(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
    }

    private func cacheKey(input: AVAudioFormat, target: ConsumerFormat) -> String {
        "\(inputFingerprint(input))→\(target.sampleRate)-\(target.channelCount)"
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer, to target: ConsumerFormat) -> AVAudioPCMBuffer? {
        let inputFormat = inputBuffer.format
        let key = cacheKey(input: inputFormat, target: target)

        // 命中输入 format 但 SR/通道相同 → 无需转换，直接透传
        if inputFormat.sampleRate == target.sampleRate &&
            inputFormat.channelCount == target.channelCount &&
            inputFormat.commonFormat == .pcmFormatFloat32 {
            return inputBuffer
        }

        guard let entry = converterEntry(inputFormat: inputFormat, target: target, key: key) else { return nil }

        let ratio = entry.outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: entry.outputFormat, frameCapacity: max(capacity, 1)) else {
            return nil
        }

        var didProvideInput = false
        var error: NSError?
        let status = entry.converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            DebugLog.error("[AudioRouter] convert 失败: \(error.localizedDescription)")
            return nil
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    private func converterEntry(
        inputFormat: AVAudioFormat,
        target: ConsumerFormat,
        key: String
    ) -> ConverterEntry? {
        converterLock.lock()
        if let cached = converterCache[key] {
            converterLock.unlock()
            return cached
        }
        let generation = converterCacheGeneration
        converterLock.unlock()

        guard let outputFormat = target.avFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            DebugLog.error("[AudioRouter] 无法创建 converter input=\(inputFingerprint(inputFormat)) target=\(target)")
            return nil
        }

        let created = ConverterEntry(converter: converter, outputFormat: outputFormat)
        converterLock.lock()
        defer { converterLock.unlock() }
        if let cached = converterCache[key] {
            return cached
        }
        if converterCacheGeneration == generation {
            converterCache[key] = created
        }
        return created
    }
}
