import AVFoundation
import Speech
import Accelerate
import CoreAudio

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
    private let bufferQueue = DispatchQueue(label: "com.atomvoice.audioBuffer")  // 保护 sampleBuffer 和静音检测状态

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

    // MARK: - 输入设备管理

    /// 音频输入设备信息
    struct AudioInputDevice {
        let id: AudioDeviceID
        let name: String
        let uid: String
    }

    /// 列出所有可用的音频输入设备
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
            // 检查是否有输入通道
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputAddr, 0, nil, &bufSize) == noErr, bufSize > 0 else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            guard AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &bufSize, bufferList) == noErr else { continue }

            let channelCount = (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { total, i in
                total + Int(UnsafeMutableAudioBufferListPointer(bufferList)[i].mNumberChannels)
            }
            guard channelCount > 0 else { continue }

            // 获取设备名称
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name)
            let deviceName = name?.takeUnretainedValue() as String? ?? "Unknown"

            // 获取设备 UID
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

    /// 将选中的输入设备应用到 AVAudioEngine
    private func applySelectedInputDevice() {
        let savedUID = UserDefaults.standard.string(forKey: "audioInputDeviceUID") ?? ""
        guard !savedUID.isEmpty else { return }  // 空 = 系统默认

        let devices = AudioEngineController.availableInputDevices()
        guard let device = devices.first(where: { $0.uid == savedUID }) else {
            print("[AudioEngine] 保存的输入设备 \(savedUID) 不可用，使用系统默认")
            return
        }

        let audioUnit = engine.inputNode.audioUnit!
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
            print("[AudioEngine] 输入设备已切换为: \(device.name)")
        } else {
            print("[AudioEngine] 切换输入设备失败: \(status)")
        }
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

        // 应用用户选择的输入设备
        applySelectedInputDevice()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = Float(format.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)

            if let channelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)

                self.bufferQueue.sync {
                    self.sampleBuffer.append(
                        contentsOf: UnsafeBufferPointer(start: channelData[0], count: count)
                    )

                    // 静音检测：用 RMS 判断音量
                    let bufferDuration = Double(count) / Double(sampleRate)
                    self.recordingDuration += bufferDuration
                    self.detectSilence(channelData: channelData[0], frameCount: count, bufferDuration: bufferDuration)

                    // 攒够 fftSize 后做 FFT，50% 重叠提高时间分辨率
                    while self.sampleBuffer.count >= self.fftSize {
                        let chunk = Array(self.sampleBuffer.prefix(self.fftSize))
                        self.sampleBuffer.removeFirst(self.fftSize / 2)
                        let bands = self.computeBands(samples: chunk, sampleRate: sampleRate)
                        self.bandsHandler?(bands)
                    }
                }
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
        bufferQueue.sync {
            sampleBuffer = []
            silenceDuration = 0
            recordingDuration = 0
        }
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
