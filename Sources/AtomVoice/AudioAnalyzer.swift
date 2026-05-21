import AVFoundation
import Accelerate

/// 音频分析器：静音检测 + 5 段频谱可视化。
/// 订阅 AudioRouter 的 16kHz mono Float32 通道，固定 SR 让频段配置和阈值不再随设备漂移。
/// 回调全部在内部 worker queue 触发，调用方负责切回主线程消费。
/// (Audio analyzer: silence detection + 5-band spectrum for visualization.
///  Subscribes to AudioRouter's 16kHz channel; fixed SR keeps band ranges and thresholds stable.
///  Callbacks fire on internal worker queue; caller dispatches to main as needed.)
final class AudioAnalyzer {
    /// 静音达到阈值时触发（在 worker queue 上）
    var onSilenceTimeout: (() -> Void)?
    /// FFT 频段更新时触发（在 worker queue 上）
    var onBands: (([Float]) -> Void)?

    // 静音自动停止
    private var silenceDuration: Double = 0
    private var recordingDuration: Double = 0
    private let silenceGuardPeriod: Double = 0.5

    // FFT
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.atomvoice.audioAnalyzer")

    // 频段配置（针对 16kHz 固定 SR）：只用人声核心频率范围，避免低频震动 / 高频噪声推起整体波形。
    private let bandFreqRanges: [(Float, Float)] = [
        (100,  260),
        (260,  650),
        (650,  1500),
        (1500, 2800),
        (2800, 4200),
    ]
    private let visualBarProfile: [Float] = [0.40, 0.68, 1.0, 0.68, 0.40]
    private let voicePresenceWeights: [Float] = [0.25, 0.85, 1.0, 0.75, 0.20]
    private let bandNoiseFloors: [Float] = [-50, -57, -61, -64, -66]

    init() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    /// 录音开始 / 结束时重置滚动状态（Clear rolling state on start/stop）
    func reset() {
        bufferQueue.sync {
            sampleBuffer = []
            silenceDuration = 0
            recordingDuration = 0
        }
    }

    /// 来自 AudioRouter 16kHz 通道的 buffer。在调用线程同步拷贝 samples，剩余处理异步到 bufferQueue。
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        let sampleRate = Float(buffer.format.sampleRate)
        let bufferDuration = Double(count) / Double(sampleRate)

        bufferQueue.async { [weak self] in
            self?.processSamplesOnWorker(samples: samples, bufferDuration: bufferDuration, sampleRate: sampleRate)
        }
    }

    // MARK: - Worker

    private func processSamplesOnWorker(samples: [Float], bufferDuration: Double, sampleRate: Float) {
        sampleBuffer.append(contentsOf: samples)
        recordingDuration += bufferDuration

        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            detectSilence(channelData: base, frameCount: samples.count, bufferDuration: bufferDuration)
        }

        // 攒够 fftSize 后做 FFT，50% 重叠提高时间分辨率
        var offset = 0
        while sampleBuffer.count - offset >= fftSize {
            let bands = sampleBuffer.withUnsafeBufferPointer { bufPtr -> [Float] in
                guard let base = bufPtr.baseAddress else { return [Float](repeating: 0, count: 5) }
                return computeBands(samplesPointer: base.advanced(by: offset), sampleRate: sampleRate)
            }
            offset += fftSize / 2
            onBands?(bands)
        }
        if offset > 0 {
            sampleBuffer.removeSubrange(0..<offset)
        }
    }

    // MARK: - 静音检测

    private func detectSilence(channelData: UnsafePointer<Float>, frameCount: Int, bufferDuration: Double) {
        guard recordingDuration > silenceGuardPeriod else { return }
        guard AppSettings.silenceAutoStopEnabled else { return }
        guard !AppSettings.tapModeManualStop else { return }

        let threshold = AppSettings.silenceThreshold
        let requiredDuration = AppSettings.silenceDuration

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let dB = 20 * log10(max(rms, 1e-7))

        if Double(dB) < threshold {
            silenceDuration += bufferDuration
            if silenceDuration >= requiredDuration {
                silenceDuration = 0
                fireSilenceTimeout()
            }
        } else {
            silenceDuration = 0
        }
    }

    private func fireSilenceTimeout() {
        DispatchQueue.main.async { [weak self] in
            self?.onSilenceTimeout?()
        }
    }

    // MARK: - FFT

    private func computeBands(samplesPointer: UnsafePointer<Float>, sampleRate: Float) -> [Float] {
        guard let fftSetup else {
            return [Float](repeating: 0, count: 5)
        }

        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samplesPointer, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)

        let bands: [Float] = real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!,
                                            imagp: imagBuf.baseAddress!)

                windowed.withUnsafeBytes { rawPtr in
                    rawPtr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                        vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                var mags = [Float](repeating: 0, count: halfSize)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfSize))
                var norm = Float(halfSize)
                vDSP_vsdiv(mags, 1, &norm, &mags, 1, vDSP_Length(halfSize))

                let freqPerBin = sampleRate / Float(self.fftSize)
                let spectralLevels = self.bandFreqRanges.enumerated().map { (i, range) in
                    let (loFreq, hiFreq) = range
                    let loIdx = max(1, Int(loFreq / freqPerBin))
                    let hiIdx = min(halfSize - 1, Int(hiFreq / freqPerBin))
                    guard loIdx < hiIdx else { return Float(0) }

                    let energy = self.bandEnergy(mags: mags, loIdx: loIdx, hiIdx: hiIdx)
                    let dB = 20.0 * log10(max(energy, 1e-7))
                    let floor = i < self.bandNoiseFloors.count ? self.bandNoiseFloors[i] : -62
                    return self.normalizedDecibels(dB, floor: floor, range: 40)
                }

                let spectralPresence = self.weightedAverage(spectralLevels, weights: self.voicePresenceWeights)
                let voiceEnergy = self.voiceGate(spectralPresence)

                return spectralLevels.enumerated().map { (i, spectral) in
                    let profile = i < self.visualBarProfile.count ? self.visualBarProfile[i] : 1
                    let texture = 0.99 + spectral * 0.025
                    return max(0, min(1, voiceEnergy * profile * texture))
                }
            }
        }

        return bands
    }

    private func bandEnergy(mags: [Float], loIdx: Int, hiIdx: Int) -> Float {
        var sum: Float = 0
        var peak: Float = 0
        let count = hiIdx - loIdx + 1

        for idx in loIdx...hiIdx {
            let value = mags[idx]
            sum += value
            if value > peak { peak = value }
        }

        let mean = sum / Float(count)
        return mean * 0.50 + peak * 0.50
    }

    private func weightedAverage(_ values: [Float], weights: [Float]) -> Float {
        var weightedSum: Float = 0
        var totalWeight: Float = 0
        for i in 0..<values.count {
            let weight = i < weights.count ? weights[i] : 1
            weightedSum += values[i] * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }

    private func voiceGate(_ level: Float) -> Float {
        max(0, min(1, (level - 0.055) / 0.84))
    }

    private func normalizedDecibels(_ dB: Float, floor: Float, range: Float) -> Float {
        max(0, min(1, (dB - floor) / range))
    }
}
