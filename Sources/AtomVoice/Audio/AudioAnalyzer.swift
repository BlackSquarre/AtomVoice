import AVFoundation
import Accelerate

struct AudioAnalysisFrame {
    let bands: [Float]
    let isVoiceLike: Bool
    let capturedAt: TimeInterval
}

/// 音频分析器：5 段人声频谱可视化。
/// 订阅 AudioRouter 的 16kHz mono Float32 通道，固定 SR 让频段配置和阈值不再随设备漂移。
/// 回调全部在内部 worker queue 触发，调用方负责切回主线程消费。
/// (Audio analyzer: 5-band voice spectrum for visualization.
///  Subscribes to AudioRouter's 16kHz channel; fixed SR keeps band ranges and thresholds stable.
///  Callbacks fire on internal worker queue; caller dispatches to main as needed.)
///
/// 本类提供声音证据；是否自动停止仍由 ASRSilenceMonitor 结合文字和用户设置决定。
final class AudioAnalyzer {
    /// FFT 频段更新时触发（在 worker queue 上）
    var onBands: (([Float]) -> Void)?
    var onAnalysis: ((AudioAnalysisFrame) -> Void)?

    // FFT
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.atomvoice.audioAnalyzer")
    #if DEBUG_BUILD
    private var lastBandsProbeLogTime: CFAbsoluteTime = 0
    #endif

    // 频段配置（针对 16kHz 固定 SR）：只用人声核心频率范围，避免低频震动 / 高频噪声推起整体波形。
    private let bandFreqRanges: [(Float, Float)] = [
        (100,  260),
        (260,  650),
        (650,  1500),
        (1500, 2800),
        (2800, 4200),
    ]
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
        bufferQueue.async { [self] in
            sampleBuffer = []
        }
    }

    /// 来自 AudioRouter 16kHz 通道的 buffer。在调用线程同步拷贝 samples，剩余处理异步到 bufferQueue。
    func accept(_ buffer: AVAudioPCMBuffer, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        let sampleRate = Float(buffer.format.sampleRate)

        bufferQueue.async { [weak self] in
            self?.processSamplesOnWorker(samples: samples, sampleRate: sampleRate, capturedAt: capturedAt)
        }
    }

    // MARK: - Worker

    private func processSamplesOnWorker(samples: [Float], sampleRate: Float, capturedAt: TimeInterval) {
        sampleBuffer.append(contentsOf: samples)

        // 攒够 fftSize 后做 FFT，50% 重叠提高时间分辨率
        var offset = 0
        while sampleBuffer.count - offset >= fftSize {
            // 按窗口位置回推输入时间，worker 积压不能把旧音频变成新的续录证据。
            let frameTime = capturedAt - Double(sampleBuffer.count - offset - fftSize) / Double(sampleRate)
            let frame = sampleBuffer.withUnsafeBufferPointer { bufPtr -> AudioAnalysisFrame in
                computeFrame(samplesPointer: bufPtr.baseAddress!.advanced(by: offset),
                             sampleRate: sampleRate, capturedAt: frameTime)
            }
            #if DEBUG_BUILD
            logBandsIfNeeded(frame.bands, sampleRate: sampleRate)
            #endif
            offset += fftSize / 2
            onAnalysis?(frame)
            onBands?(frame.bands)
        }
        if offset > 0 {
            sampleBuffer.removeSubrange(0..<offset)
        }
    }

    // MARK: - FFT

    private func computeFrame(samplesPointer: UnsafePointer<Float>, sampleRate: Float,
                              capturedAt: TimeInterval) -> AudioAnalysisFrame {
        guard let fftSetup else {
            return AudioAnalysisFrame(bands: [Float](repeating: 0, count: 5), isVoiceLike: false, capturedAt: capturedAt)
        }

        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samplesPointer, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)

        let frame: AudioAnalysisFrame = real.withUnsafeMutableBufferPointer { realBuf in
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

                let bands = spectralLevels.map { spectral in
                    // 每条以自身频段为主，少量整体能量保持窄频声音的连贯感。
                    // 轻压缩让低声更容易看见，静音底仍由上面的频谱噪声门控制。
                    let level = self.voiceGate(spectral * 0.82 + spectralPresence * 0.18)
                    return pow(level, 0.85)
                }
                return AudioAnalysisFrame(bands: bands,
                                          isVoiceLike: self.onAnalysis != nil && self.isVoiceLike(
                                            samplesPointer: samplesPointer, mags: mags, sampleRate: sampleRate),
                                          capturedAt: capturedAt)
            }
        }

        return frame
    }

    /// 复用当前 FFT 筛选有声段；稳定长音仍算声音，不按音量方差把它判成噪声。
    /// 这是轻量证据，无法区分与人声频谱相似的机器长音，文字心跳仍需兜底。
    private func isVoiceLike(samplesPointer: UnsafePointer<Float>, mags: [Float], sampleRate: Float) -> Bool {
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samplesPointer, 1, &rms, vDSP_Length(fftSize))
        vDSP_maxmgv(samplesPointer, 1, &peak, vDSP_Length(fftSize))
        guard rms.isFinite, rms >= 0.0012589254, peak / rms <= 10 else { return false }

        let binWidth = sampleRate / Float(fftSize)
        let lower = max(1, Int(ceil(70 / binWidth)))
        let upper = min(mags.count - 1, Int(4200 / binWidth))
        guard lower + 2 <= upper else { return false }
        var totalPower: Float = 0
        var voicePower: Float = 0
        var strongestCluster: Float = 0
        var previousPower: Float = 0
        var secondPreviousPower: Float = 0
        for index in 1..<mags.count {
            let power = mags[index] * mags[index]
            totalPower += power
            if index >= lower && index <= upper {
                voicePower += power
                strongestCluster = max(strongestCluster, power + previousPower + secondPreviousPower)
                secondPreviousPower = previousPower
                previousPower = power
            }
        }
        guard totalPower.isFinite, totalPower > 0, voicePower > 0 else { return false }
        return voicePower / totalPower >= 0.55 && strongestCluster / voicePower >= 0.20
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

    #if DEBUG_BUILD
    private func logBandsIfNeeded(_ bands: [Float], sampleRate: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBandsProbeLogTime >= 0.5 else { return }
        lastBandsProbeLogTime = now
        let maxBand = bands.max() ?? 0
        let text = bands.map { String(format: "%.3f", $0) }.joined(separator: ",")
        DebugLog.info(String(format: "[AudioAnalyzer] bands max=%.3f sr=%.0f values=[%@]", maxBand, sampleRate, text))
    }
    #endif
}
