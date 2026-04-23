import AVFoundation
import Speech
import Accelerate

final class AudioEngineController {
    let engine = AVAudioEngine()
    private var bandsHandler: (([Float]) -> Void)?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    // 静音自动停止
    var onSilenceTimeout: (() -> Void)?
    private var silenceDuration: Double = 0
    private var recordingDuration: Double = 0
    private let silenceGuardPeriod: Double = 0.5  // 录音前 0.5 秒不检测静音

    // FFT
    private let fftSize = 2048
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleBuffer: [Float] = []

    // 只覆盖人声核心频率范围 100–6000 Hz
    // 男声基频 85-180Hz → 第2根；女声上共振峰 2000-4000Hz → 第4根
    private let bandFreqRanges: [(Float, Float)] = [
        (100,  280),   // 第1根 — 男声基频区
        (280,  700),   // 第2根 — 男声低共振峰 F1（元音能量主体）
        (700,  2000),  // 第3根 — 语音核心 F1/F2 重叠区，男女声均在此
        (2000, 4000),  // 第4根 — 女声高共振峰 F2/F3
        (4000, 6000),  // 第5根 — 辅音定义/齿音边缘
    ]

    init() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    /// 滚动分段时切换识别请求，后续 buffer 将推送到新请求
    func switchRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest) {
        recognitionRequest = newRequest
    }

    func start(bandsHandler: @escaping ([Float]) -> Void,
               recognitionRequest: SFSpeechAudioBufferRecognitionRequest?) {
        self.bandsHandler = bandsHandler
        self.recognitionRequest = recognitionRequest
        sampleBuffer = []
        silenceDuration = 0
        recordingDuration = 0

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = Float(format.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)

            if let channelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                self.sampleBuffer.append(
                    contentsOf: UnsafeBufferPointer(start: channelData[0], count: count)
                )

                // 静音检测：用 RMS 判断音量
                let bufferDuration = Double(count) / Double(sampleRate)
                self.recordingDuration += bufferDuration
                self.detectSilence(channelData: channelData[0], frameCount: count, bufferDuration: bufferDuration)
            }

            // 攒够 fftSize 后做 FFT，50% 重叠提高时间分辨率
            while self.sampleBuffer.count >= self.fftSize {
                let chunk = Array(self.sampleBuffer.prefix(self.fftSize))
                self.sampleBuffer.removeFirst(self.fftSize / 2)
                let bands = self.computeBands(samples: chunk, sampleRate: sampleRate)
                self.bandsHandler?(bands)
            }
        }

        do { try engine.start() }
        catch { print("[AudioEngine] 启动失败: \(error)") }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bandsHandler = nil
        recognitionRequest = nil
        sampleBuffer = []
        silenceDuration = 0
        recordingDuration = 0
    }

    // MARK: - 静音检测

    private func detectSilence(channelData: UnsafeMutablePointer<Float>, frameCount: Int, bufferDuration: Double) {
        // 保护期内不检测
        guard recordingDuration > silenceGuardPeriod else { return }

        // 读取用户设置
        let enabled = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        guard enabled else { return }

        let threshold = UserDefaults.standard.double(forKey: "silenceThreshold")
        let requiredDuration = UserDefaults.standard.double(forKey: "silenceDuration")

        // 计算 RMS（用 Accelerate，几乎零开销）
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let dB = 20 * log10(max(rms, 1e-7))

        if Double(dB) < threshold {
            silenceDuration += bufferDuration
            if silenceDuration >= requiredDuration {
                silenceDuration = 0  // 防止重复触发
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        } else {
            silenceDuration = 0
        }
    }

    // MARK: - FFT

    private func computeBands(samples: [Float], sampleRate: Float) -> [Float] {
        guard let fftSetup, samples.count == fftSize else {
            return [Float](repeating: 0, count: 5)
        }

        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        // 加汉宁窗
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // 实数 FFT
        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)

        let bands: [Float] = real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!,
                                            imagp: imagBuf.baseAddress!)

                // 把 real 信号打包成复数格式
                windowed.withUnsafeBytes { rawPtr in
                    rawPtr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                        vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // 幅度（不是功率），正确归一化：除以 N 再取 sqrt
                var mags = [Float](repeating: 0, count: halfSize)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfSize))
                // vDSP_zvabs 输出是 sqrt(r²+i²)，但 zrip 的输出在 0 号位不含虚部
                // 归一化：除以 (fftSize/2)
                var norm = Float(halfSize)
                vDSP_vsdiv(mags, 1, &norm, &mags, 1, vDSP_Length(halfSize))

                // 按频率范围切分频段，取均值后转 dB，映射到 0-1
                let freqPerBin = sampleRate / Float(self.fftSize)
                return self.bandFreqRanges.enumerated().map { (i, range) in
                    let (loFreq, hiFreq) = range
                    let loIdx = max(1, Int(loFreq / freqPerBin))
                    let hiIdx = min(halfSize - 1, Int(hiFreq / freqPerBin))
                    guard loIdx < hiIdx else { return Float(0) }

                    let slice = mags[loIdx...hiIdx]
                    let mean = slice.reduce(0, +) / Float(slice.count)

                    // 对数映射：各频段使用不同灵敏度
                    // 第1根（超低频）不需要太灵敏，中间三根最灵敏，第5根齿音偏高
                    let dB = 20.0 * log10(max(mean, 1e-7))
                    let floors: [Float] = [-60, -65, -68, -65, -58]
                    let floor = i < floors.count ? floors[i] : -65
                    let range: Float = 48
                    let normalized = (dB - floor) / range
                    return max(0, min(1, normalized))
                }
            }
        }

        return bands
    }
}
