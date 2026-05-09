import AVFoundation
import Speech
import Accelerate
import CoreAudio
import AudioTapShim

final class AudioEngineController {
    let engine = AVAudioEngine()
    private var bandsHandler: (([Float]) -> Void)?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioBufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var tapInstalled = false

    // 静音自动停止（Silence auto-stop）
    var onSilenceTimeout: (() -> Void)?
    private var silenceDuration: Double = 0
    private var recordingDuration: Double = 0
    private let silenceGuardPeriod: Double = 0.5  // 录音前 0.5 秒不检测静音（Skip silence detection for the first 0.5s）

    // 持续噪声检测（Steady noise detection）
    // 如果音频能量长时间稳定（方差低），说明是持续噪声而非人声
    // (If audio energy is stable for a long time (low variance), it's steady noise, not speech)
    private var rmsHistory: [Float] = []
    private let rmsHistorySize = 30  // 记录最近 30 个 RMS 值（约 1.5 秒）(Keep last 30 RMS values, ~1.5 seconds)
    private var steadyNoiseDuration: Double = 0
    // 方差阈值：越小越难触发（需要更稳定的噪声）；越大越容易触发
    // (Variance threshold: smaller = harder to trigger (needs steadier noise); larger = easier to trigger)
    private var steadyNoiseThreshold: Float = 0.001

    // FFT
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.atomvoice.audioBuffer")  // 保护 sampleBuffer 和静音检测状态（Protect sampleBuffer and silence detection state）

    // 只用人声核心频率范围驱动视觉，避免低频震动/高频噪声把波形整体推起来。（Use only core voice frequency ranges for visuals, avoiding low-freq rumble/high-freq noise from inflating the waveform.）
    // 频谱只判断人声存在感，最终仍映射为 logo 式居中分布。（Spectrum only determines voice presence; final mapping uses logo-style centered distribution.）
    private let bandFreqRanges: [(Float, Float)] = [
        (100,  260),   // 第1根 — 男声低频轮廓（Bar 1 — male low-freq contour）
        (260,  650),   // 第2根 — 低共振峰（Bar 2 — low formant）
        (650,  1500),  // 第3根 — 元音主体（Bar 3 — vowel core）
        (1500, 2800),  // 第4根 — 清晰度与高共振峰（Bar 4 — clarity & high formant）
        (2800, 4200),  // 第5根 — 辅音边缘，权重较低（Bar 5 — consonant edge, lower weight）
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

    // MARK: - 输入设备管理

    /// 音频输入设备信息（Audio input device info）
    struct AudioInputDevice {
        let id: AudioDeviceID
        let name: String
        let uid: String
    }

    /// 列出所有可用的音频输入设备（List all available audio input devices）
    static func availableInputDevices() -> [AudioInputDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for id in deviceIDs {
            // 检查是否有输入通道（Check for input channels）
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputAddr, 0, nil, &bufSize) == noErr, bufSize > 0 else { continue }

            let rawBuffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(bufSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { rawBuffer.deallocate() }

            let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &bufSize, bufferList) == noErr else { continue }

            let channelCount = (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { total, i in
                total + Int(UnsafeMutableAudioBufferListPointer(bufferList)[i].mNumberChannels)
            }
            guard channelCount > 0 else { continue }

            // 获取设备名称（Get device name）
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name)
            let deviceName = name?.takeUnretainedValue() as String? ?? "Unknown"

            // 获取设备 UID（Get device UID）
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid)
            let deviceUID = uid?.takeUnretainedValue() as String? ?? ""

            result.append(AudioInputDevice(id: id, name: deviceName, uid: deviceUID))
        }
        return result
    }

    /// 将选中的输入设备应用到 AVAudioEngine（Apply selected input device to AVAudioEngine）
    private func applySelectedInputDevice() {
        let savedUID = AppSettings.audioInputDeviceUID
        guard !savedUID.isEmpty else { return }  // 空 = 系统默认（Empty = system default）

        let devices = AudioEngineController.availableInputDevices()
        guard let device = devices.first(where: { $0.uid == savedUID }) else {
            DebugLog.info("[AudioEngine] 保存的输入设备 \(savedUID) 不可用，使用系统默认")
            return
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            DebugLog.error("[AudioEngine] 输入节点不可用，无法切换输入设备")
            return
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            DebugLog.info("[AudioEngine] 输入设备已切换为: \(device.name)")
        } else {
            DebugLog.error("[AudioEngine] 切换输入设备失败: \(status)")
        }
    }

    /// 滚动分段时切换识别请求，后续 buffer 将推送到新请求（Switch recognition request during scroll; subsequent buffers will be pushed to the new request）
    func switchRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest) {
        recognitionRequest = newRequest
    }

    @discardableResult
    func start(bandsHandler: @escaping ([Float]) -> Void,
               recognitionRequest: SFSpeechAudioBufferRecognitionRequest?,
               audioBufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? = nil) -> Bool {
        stop()

        self.bandsHandler = bandsHandler
        self.recognitionRequest = recognitionRequest
        self.audioBufferHandler = audioBufferHandler
        bufferQueue.sync {
            sampleBuffer = []
            silenceDuration = 0
            recordingDuration = 0
        }

        // 应用用户选择的输入设备（Apply user-selected input device）
        applySelectedInputDevice()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DebugLog.error("[AudioEngine] 输入格式无效: sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)")
            stop()
            return false
        }
        let sampleRate = Float(format.sampleRate)

        let installed = AtomVoiceInstallAudioTap(inputNode, 0, 1024, format) { [weak self] buffer, time in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.audioBufferHandler?(buffer, time)

            if let channelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)

                self.bufferQueue.sync {
                    self.sampleBuffer.append(
                        contentsOf: UnsafeBufferPointer(start: channelData[0], count: count)
                    )

                    // 静音检测：用 RMS 判断音量（Silence detection: judge volume by RMS）
                    let bufferDuration = Double(count) / Double(sampleRate)
                    self.recordingDuration += bufferDuration
                    self.detectSilence(channelData: channelData[0], frameCount: count, bufferDuration: bufferDuration)

                    // 攒够 fftSize 后做 FFT，50% 重叠提高时间分辨率（Perform FFT when enough samples accumulate, 50% overlap for better time resolution）
                    var offset = 0
                    while self.sampleBuffer.count - offset >= self.fftSize {
                        let chunk = Array(self.sampleBuffer[offset..<(offset + self.fftSize)])
                        offset += self.fftSize / 2
                        let bands = self.computeBands(samples: chunk, sampleRate: sampleRate)
                        self.bandsHandler?(bands)
                    }
                    if offset > 0 {
                        self.sampleBuffer.removeSubrange(0..<offset)
                    }
                }
            }
        }
        guard installed else {
            stop()
            return false
        }
        tapInstalled = true

        do {
            try engine.start()
            return true
        } catch {
            DebugLog.error("[AudioEngine] 启动失败: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        bandsHandler = nil
        recognitionRequest = nil
        audioBufferHandler = nil
        bufferQueue.sync {
            sampleBuffer = []
            silenceDuration = 0
            steadyNoiseDuration = 0
            rmsHistory = []
            recordingDuration = 0
        }
    }

    // MARK: - 静音检测

    private func detectSilence(channelData: UnsafeMutablePointer<Float>, frameCount: Int, bufferDuration: Double) {
        // 保护期内不检测（Skip detection during guard period）
        guard recordingDuration > silenceGuardPeriod else { return }

        // 读取用户设置（Read user settings）
        guard AppSettings.silenceAutoStopEnabled else { return }

        let threshold = AppSettings.silenceThreshold
        let requiredDuration = AppSettings.silenceDuration

        // 更新持续噪声灵敏度设置（Update steady noise sensitivity setting）
        let sensitivity = AppSettings.steadyNoiseSensitivity
        switch sensitivity {
        case 0: steadyNoiseThreshold = 0.0005  // 低灵敏度：需要非常稳定的噪声才触发 (Low: needs very steady noise)
        case 2: steadyNoiseThreshold = 0.003   // 高灵敏度：较容易触发 (High: triggers easier)
        default: steadyNoiseThreshold = 0.001   // 中灵敏度 (Medium)
        }

        // 计算 RMS（用 Accelerate，几乎零开销）（Compute RMS via Accelerate, near-zero overhead）
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let dB = 20 * log10(max(rms, 1e-7))

        // 更新 RMS 历史，用于持续噪声检测（Update RMS history for steady noise detection）
        rmsHistory.append(rms)
        if rmsHistory.count > rmsHistorySize {
            rmsHistory.removeFirst()
        }

        // 检测持续噪声：RMS 有值但方差很低（Detect steady noise: RMS is present but variance is low）
        let isSteadyNoise = rmsHistory.count >= rmsHistorySize && detectSteadyNoise(rmsHistory: rmsHistory, currentRMS: rms)

        if Double(dB) < threshold {
            // 完全静音（Complete silence）
            silenceDuration += bufferDuration
            steadyNoiseDuration = 0
            if silenceDuration >= requiredDuration {
                silenceDuration = 0  // 防止重复触发（Prevent repeated triggers）
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        } else if isSteadyNoise {
            // 持续噪声（如空调、风扇）：能量稳定，不是人声（Steady noise like AC/fan: stable energy, not speech）
            silenceDuration = 0
            steadyNoiseDuration += bufferDuration
            if steadyNoiseDuration >= requiredDuration {
                steadyNoiseDuration = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        } else {
            // 有人声（Speech detected）
            silenceDuration = 0
            steadyNoiseDuration = 0
        }
    }

    /// 检测持续噪声：RMS 有值但方差很低（Detect steady noise: RMS is present but variance is low）
    private func detectSteadyNoise(rmsHistory: [Float], currentRMS: Float) -> Bool {
        // 只在 RMS 高于完全静音阈值时才检测（Only check when RMS is above complete silence）
        // 避免把真正的安静误判为噪声（Avoid misjudging real silence as noise）
        guard currentRMS > 0.005 else { return false }

        // 计算 RMS 方差（Compute RMS variance）
        var mean: Float = 0
        vDSP_meanv(rmsHistory, 1, &mean, vDSP_Length(rmsHistory.count))

        var variance: Float = 0
        var squaredDiffs = [Float](repeating: 0, count: rmsHistory.count)
        let meanVec = [Float](repeating: mean, count: rmsHistory.count)
        vDSP_vsub(rmsHistory, 1, meanVec, 1, &squaredDiffs, 1, vDSP_Length(rmsHistory.count))
        vDSP_vsq(squaredDiffs, 1, &squaredDiffs, 1, vDSP_Length(rmsHistory.count))
        vDSP_meanv(squaredDiffs, 1, &variance, vDSP_Length(rmsHistory.count))

        return variance < steadyNoiseThreshold
    }

    // MARK: - FFT

    private func computeBands(samples: [Float], sampleRate: Float) -> [Float] {
        guard let fftSetup, samples.count == fftSize else {
            return [Float](repeating: 0, count: 5)
        }

        let halfSize = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        // 加汉宁窗（Apply Hanning window）
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // 实数 FFT（Real-valued FFT）
        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)

        let bands: [Float] = real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!,
                                            imagp: imagBuf.baseAddress!)

                // 把 real 信号打包成复数格式（Pack real signal into complex format）
                windowed.withUnsafeBytes { rawPtr in
                    rawPtr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                        vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // 幅度（不是功率），正确归一化：除以 N 再取 sqrt（Magnitude (not power), correct normalization: divide by N then sqrt）
                var mags = [Float](repeating: 0, count: halfSize)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfSize))
                // vDSP_zvabs 输出是 sqrt(r²+i²)，但 zrip 的输出在 0 号位不含虚部（vDSP_zvabs outputs sqrt(r²+i²), but zrip output at index 0 has no imaginary part）
                // 归一化：除以 (fftSize/2)（Normalization: divide by fftSize/2）
                var norm = Float(halfSize)
                vDSP_vsdiv(mags, 1, &norm, &mags, 1, vDSP_Length(halfSize))

                // 频谱只用于判断“有人声”和制造细微纹理，不再使用全频 RMS。（Spectrum only determines “voice present” and creates subtle texture; no longer using full-band RMS.）
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

                    // 应用图标式分布：全人声居中，两侧随动但不抢视觉重心。（Apply icon-style distribution: voice centered, sides follow but don't steal visual focus.）
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
