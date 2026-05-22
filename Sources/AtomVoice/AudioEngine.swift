import AVFoundation
import Speech
import CoreAudio
import AudioTapShim

final class AudioEngineController {
    private(set) var engine = AVAudioEngine()
    private var tapInstalled = false
    private let routeRecoveryQueue = DispatchQueue(label: "com.atomvoice.audioEngine.routeRecovery", qos: .userInitiated)
    private let routeRecoveryLock = NSLock()
    private var routeRecoveryToken = 0
    var onRouteRecoveryFailed: (() -> Void)?

    /// 音频路由：tap 收到的 buffer 经 router 分发到各消费者（按目标 format 自动重采样）。
    /// 静音检测/频谱可视化通过 AudioAnalyzer（router 的 16kHz 消费者）实现，本类只负责 source。
    /// (Audio router: tap buffer dispatched to consumers; analysis lives in AudioAnalyzer.)
    let router = AudioRouter()

    /// Apple Live Fallback 调 switchRequest 时挂载的 nil-format 消费者 id。
    /// (Consumer id for the SFSpeechAudioBufferRecognitionRequest currently switched in.)
    private var switchedRequestConsumerID: UUID?
    /// 最近一次成功完成 start() 的时间戳；用于过滤"自己触发"的 ConfigurationChange 通知。
    /// (Timestamp of the most recent successful start(); used to filter self-induced ConfigurationChange events.)
    private var lastStartSucceededAt: Date?
    /// 标记：真实路由变化后 engine 实例已不可用，下次 start() 前必须重建。
    /// (Flag: real route-change occurred; engine is corrupted, must rebuild before next start().)
    private var needsEngineRebuild = false
    #if DEBUG_BUILD
    private var lastInputProbeLogTime: CFAbsoluteTime = 0
    #endif

    private func nextRouteRecoveryToken() -> Int {
        routeRecoveryLock.lock()
        defer { routeRecoveryLock.unlock() }
        routeRecoveryToken += 1
        return routeRecoveryToken
    }

    private func invalidateRouteRecovery() {
        _ = nextRouteRecoveryToken()
    }

    private func completeRouteRecovery(token: Int) {
        routeRecoveryLock.lock()
        defer { routeRecoveryLock.unlock() }
        guard routeRecoveryToken == token else { return }
        routeRecoveryToken += 1
    }

    private func isCurrentRouteRecovery(_ token: Int) -> Bool {
        routeRecoveryLock.lock()
        defer { routeRecoveryLock.unlock() }
        return routeRecoveryToken == token
    }

    init() {
        // 监听音频路由变化（如摘下 AirPods）：engine 的 inputNode 不会自动跟随系统默认输入变化，
        // 必须在路由变化后主动 stop + reset，下次 start() 才能重新绑定到新的默认设备。
        registerConfigurationChangeObserver()
    }

    private func registerConfigurationChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    /// 销毁当前 engine 并新建一个：真实路由变化后唯一可靠的恢复路径。
    /// (Tear down current engine and create a fresh one — the only reliable recovery after real route changes.)
    private func rebuildEngine() {
        DebugLog.info("[AudioEngine] 重建 AVAudioEngine 实例 (start)")
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        if tapInstalled {
            DebugLog.info("[AudioEngine] rebuild: removeTap")
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            DebugLog.info("[AudioEngine] rebuild: engine.stop")
            engine.stop()
        }
        DebugLog.info("[AudioEngine] rebuild: 实例化新 AVAudioEngine")
        engine = AVAudioEngine()
        registerConfigurationChangeObserver()
        needsEngineRebuild = false
        lastStartSucceededAt = nil
        // 新 engine 的 input format 通常与旧的不同，丢弃 router 里所有 converter cache
        router.invalidate()
        DebugLog.info("[AudioEngine] 重建 AVAudioEngine 实例 (done)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleConfigurationChange(_ note: Notification) {
        DebugLog.info("[AudioEngine] 收到 AVAudioEngineConfigurationChange")
        // 通知可能在任意线程；统一切回主线程操作 engine 状态。
        // Apple 行为：configuration change 时 engine 会自动 stop 自己；这里只需清掉 tap 状态，
        // 让下次 start() 走干净路径。不调用 engine.reset() —— 它会让 inputNode 的格式与 AU 配置不一致，
        // 导致 installTapOnBus 报 "Failed to create tap due to format mismatch"。
        // (Notification can arrive on any thread; marshal to main. Per Apple, engine auto-stops on config change;
        //  we only clear tap state. Do NOT call engine.reset() — it desynchronizes inputNode format from the AU
        //  and causes installTapOnBus to throw "format mismatch".)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 自触发窗口（engine.start 后 ~1s 内）：系统常会延迟回吐一次 ConfigurationChange，
            // 不代表真实路由变化，忽略。否则视为真实路由变化（如摘耳机），标记 engine 需要重建。
            // 真实路由变化后旧 AVAudioEngine 实例的 inputNode 会进入"format 缓存与底层 AU 不一致"
            // 的损坏状态，installTapOnBus 会持续抛 "Failed to create tap due to format mismatch"，
            // 唯一可靠的恢复路径是丢掉整个 engine 实例重建。
            // (Self-induced echo within ~1s → ignore. Otherwise, real route change → mark engine for rebuild;
            //  the only reliable recovery from a real route change is to discard and recreate the engine.)
            if let last = self.lastStartSucceededAt,
               Date().timeIntervalSince(last) < 1.0,
               self.engine.isRunning {
                DebugLog.info("[AudioEngine] 忽略 start 后 \(Int(Date().timeIntervalSince(last)*1000))ms 内的自触发 ConfigurationChange")
                return
            }
            let wasActive = self.tapInstalled
            NSLog("[ATOMVOICE] route-change handler PRE-cleanup wasActive=%d", wasActive ? 1 : 0)
            DebugLog.info("[AudioEngine] 检测到真实路由变化，wasActive=\(wasActive)")
            // 清掉旧 engine 状态
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            if self.engine.isRunning {
                self.engine.stop()
            }
            self.needsEngineRebuild = true

            // 如果当前是活跃录音（用户还在按着触发键），就地做无缝设备切换：
            // 重建 engine + 用同一套 handler 重新装 tap & 启动。复用同一个 recognitionRequest，
            // 新设备来的 PCM 直接追加进去，录音不中断。
            // 注：曾试过"复用 engine 仅重装 tap"的快路径，但 inputNode.outputFormat 在路由变化后返回旧设备
            // 的缓存格式，installTap 必然 format mismatch。只有新建 AVAudioEngine 实例才能读到新格式。
            // (Seamless mid-recording device swap requires a fresh AVAudioEngine — outputFormat is cached
            //  on the old instance and won't reflect the new device.)
            if wasActive {
                let token = self.nextRouteRecoveryToken()
                self.scheduleRouteRecovery(token: token)
            } else {
                let token = self.nextRouteRecoveryToken()
                self.scheduleIdleRouteRebuild(token: token)
            }
        }
    }

    private func scheduleIdleRouteRebuild(token: Int) {
        DebugLog.info("[AudioEngine] 空闲路由变化后安排重建 token=\(token)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isCurrentRouteRecovery(token) else { return }
            guard self.needsEngineRebuild else {
                self.completeRouteRecovery(token: token)
                return
            }
            self.rebuildEngine()
            self.completeRouteRecovery(token: token)
            DebugLog.info("[AudioEngine] 空闲路由变化后已预重建")
        }
    }

    private func scheduleRouteRecovery(token: Int) {
        DebugLog.info("[AudioEngine] 路由变化恢复已转入后台队列 token=\(token)")
        routeRecoveryQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.recoverRouteAfterActiveChange(token: token)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isCurrentRouteRecovery(token) else { return }
            DebugLog.error("[AudioEngine] 路由变化恢复 watchdog 超时，结束当前录音 token=\(token)")
            self.completeRouteRecovery(token: token)
            self.onRouteRecoveryFailed?()
        }
    }

    private func recoverRouteAfterActiveChange(token: Int) {
        let deadline = Date().addingTimeInterval(1.5)
        var attempt = 0

        while isCurrentRouteRecovery(token), Date() < deadline {
            attempt += 1
            NSLog("[ATOMVOICE] route-change before rebuild")

            // AVAudioEngine 不是线程安全的，必须在主线程操作 engine 状态（rebuild + arm）。
            // 后台线程只负责重试间隔和 token 校验。
            // (AVAudioEngine is not thread-safe; engine mutation (rebuild + arm) must happen on the main thread.
            //  The background queue only handles retry intervals and token validation.)
            var armSuccess = false
            DispatchQueue.main.sync { [self] in
                guard isCurrentRouteRecovery(token) else { return }
                rebuildEngine()
                guard isCurrentRouteRecovery(token) else { return }
                DebugLog.info("[AudioEngine] 路由变化后台重启尝试 \(attempt)")
                armSuccess = armEngineWithCurrentHandlers(context: "route-change re-arm")
            }

            guard isCurrentRouteRecovery(token) else { return }
            NSLog("[ATOMVOICE] route-change before re-arm")

            if armSuccess {
                guard isCurrentRouteRecovery(token) else {
                    DispatchQueue.main.sync { [self] in stop() }
                    return
                }
                completeRouteRecovery(token: token)
                NSLog("[ATOMVOICE] route-change AFTER re-arm OK")
                DebugLog.info("[AudioEngine] 路由变化后无缝切到新设备成功")
                return
            }

            Thread.sleep(forTimeInterval: 0.15)
        }

        guard isCurrentRouteRecovery(token) else { return }
        DebugLog.error("[AudioEngine] 路由变化后台重启超时，结束当前录音")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentRouteRecovery(token) else { return }
            self.onRouteRecoveryFailed?()
        }
    }

    /// 读取 audio unit 当前绑定的输入设备 ID（Read currently-bound input device on audio unit）
    private func currentAudioUnitInputDeviceID() -> AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : nil
    }

    /// 读取系统当前默认输入设备 ID（Read current system default input device）
    private func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    #if DEBUG_BUILD
    private func audioDeviceName(_ deviceID: AudioDeviceID?) -> String {
        guard let deviceID else { return "nil" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return "\(deviceID)(status=\(status))" }
        return name?.takeUnretainedValue() as String? ?? "\(deviceID)"
    }

    private func logInputLevelIfNeeded(_ buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInputProbeLogTime >= 0.5 else { return }
        lastInputProbeLogTime = now

        guard let channelData = buffer.floatChannelData else {
            DebugLog.info("[AudioEngine] input-level: no floatChannelData format=\(buffer.format)")
            return
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        var sumSquares: Float = 0
        var peak: Float = 0
        for channel in 0..<channels {
            let samples = channelData[channel]
            for i in 0..<frames {
                let sample = samples[i]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
        }
        let count = Float(frames * channels)
        let rms = sqrt(sumSquares / max(count, 1))
        DebugLog.info(String(format: "[AudioEngine] input-level rms=%.6f peak=%.6f frames=%d sr=%.0f ch=%d", rms, peak, frames, buffer.format.sampleRate, channels))
    }
    #endif

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

    /// 异步等待输入路径就绪（设备列表非空 + inputNode 输入格式有效）。
    /// 在 AirPods 等热插拔造成的音频路由过渡期里，500ms 内通常可以稳定下来；不阻塞主线程。
    /// (Async-wait until input path is ready: non-empty device list + valid inputNode format.
    ///  Tolerates audio-route transitions from AirPods hot-plug without blocking the main thread.)
    func waitForInputReady(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        // 若 engine 因路由变化标记为需重建，跳过 preflight：start() 内会重建后再做正式校验。
        // 不在这里操作旧 engine，避免在损坏实例上读 format / 写 AU property。
        // (If engine is flagged for rebuild, skip preflight — start() will rebuild and validate.)
        if needsEngineRebuild {
            DebugLog.info("[AudioEngine] waitForInputReady: 跳过（engine 待重建）")
            DispatchQueue.main.async { completion(true) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let started = Date()
            let pollInterval: TimeInterval = 0.05
            let deadline = started.addingTimeInterval(timeout)
            var attempts = 0
            while Date() < deadline {
                attempts += 1
                if self.isInputReady() {
                    let elapsed = Date().timeIntervalSince(started) * 1000
                    DebugLog.info("[AudioEngine] waitForInputReady ✓ ready after \(Int(elapsed))ms (attempts=\(attempts))")
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            attempts += 1
            let ok = self.isInputReady()
            let elapsed = Date().timeIntervalSince(started) * 1000
            DebugLog.info("[AudioEngine] waitForInputReady \(ok ? "✓" : "✗") final after \(Int(elapsed))ms (attempts=\(attempts))")
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 单次检查输入路径是否就绪（Single-shot check that input path is ready）
    private func isInputReady() -> Bool {
        let devices = AudioEngineController.availableInputDevices()
        guard !devices.isEmpty else {
            DebugLog.info("[AudioEngine] isInputReady: 设备列表为空")
            return false
        }
        applySelectedInputDevice()
        var format = engine.inputNode.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount <= 0 {
            let names = devices.map { $0.name }.joined(separator: ",")
            DebugLog.info("[AudioEngine] isInputReady: format 无效 sr=\(format.sampleRate) ch=\(format.channelCount), 设备数=\(devices.count) 名单=\(names)，尝试 forceRebind")
            forceRebindDefaultInputDevice()
            format = engine.inputNode.outputFormat(forBus: 0)
            DebugLog.info("[AudioEngine] isInputReady: forceRebind 后 format sr=\(format.sampleRate) ch=\(format.channelCount)")
        }
        return format.sampleRate > 0 && format.channelCount > 0
    }

    /// 把系统默认输入设备显式写回 audio unit，强制 AVAudioEngine 解除对失效设备的绑定。
    /// (Force-rebind AVAudioEngine input to the current default input device.)
    private func forceRebindDefaultInputDevice() {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            DebugLog.error("[AudioEngine] 强制重绑默认输入设备失败 status=\(status) deviceID=\(deviceID)")
        } else {
            DebugLog.info("[AudioEngine] 强制重绑默认输入设备成功 deviceID=\(deviceID)")
        }
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

    /// Apple Live Fallback 切换识别请求时调用：以 nil-format 透传消费者方式接入 router。
    /// 当前只有 Apple Live Fallback（豆包失败后回退到 Apple Speech）用此 API。
    /// (Used by Apple Live Fallback when Doubao fails; subsequent buffers feed the new request.)
    func switchRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest) {
        if let id = switchedRequestConsumerID {
            router.unregister(id)
        }
        switchedRequestConsumerID = router.register(format: nil) { buffer in
            newRequest.append(buffer)
        }
    }

    /// 录音结束时清理 switchRequest 留下的消费者（Cleanup on recording stop）
    func clearSwitchedRequest() {
        if let id = switchedRequestConsumerID {
            router.unregister(id)
            switchedRequestConsumerID = nil
        }
    }

    @discardableResult
    func start() -> Bool {
        stop()

        if needsEngineRebuild {
            rebuildEngine()
        }

        // 应用输入设备：仅在用户明确选了具体设备时才 setProperty。
        // 默认设备（UID 为空）路径完全不动 AU —— AVAudioEngine 初始化时自动绑定系统当前默认输入，
        // 任何 setProperty 都可能让 AU 进入 "format 未协商完成" 的中间态，导致 engine.start 抛
        // kAudioUnitErr_FormatNotSupported (-10868) 或 installTap format mismatch。
        // 路由变化（如摘耳机）由 ConfigurationChange 监听 → 标记 needsEngineRebuild → 下次 start()
        // 时重建 AVAudioEngine 实例处理；新 engine 自动绑定到新的系统默认输入。
        // (Default-device path: do NOT touch AU. Fresh AVAudioEngine binds to current default natively;
        //  any setProperty risks leaving AU in a half-negotiated state. Route changes are handled by
        //  rebuilding the engine on the next start().)
        if !AppSettings.audioInputDeviceUID.isEmpty {
            applySelectedInputDevice()
        }

        return armEngineWithCurrentHandlers(context: "start")
    }

    /// 装 tap 并启动 engine。失败时标记 needsEngineRebuild。
    /// (Install tap and start engine; flag rebuild on failure.)
    private func armEngineWithCurrentHandlers(context: String) -> Bool {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        DebugLog.info("[AudioEngine] \(context): format sr=\(format.sampleRate) ch=\(format.channelCount)")
        #if DEBUG_BUILD
        DebugLog.info("[AudioEngine] \(context): boundInput=\(audioDeviceName(currentAudioUnitInputDeviceID())) defaultInput=\(audioDeviceName(systemDefaultInputDeviceID())) selectedUID=\(AppSettings.audioInputDeviceUID.isEmpty ? "system-default" : AppSettings.audioInputDeviceUID)")
        lastInputProbeLogTime = 0
        #endif
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DebugLog.error("[AudioEngine] \(context): 输入格式无效")
            needsEngineRebuild = true
            return false
        }

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            // tap 唯一职责：把 buffer 交给 router，由 router 按消费者目标 format 分发。
            // (Tap's sole job: hand buffer to router for fan-out by target format.)
            #if DEBUG_BUILD
            self?.logInputLevelIfNeeded(buffer)
            #endif
            self?.router.receive(buffer)
        }

        var tapError: NSString?
        let installed = AtomVoiceInstallAudioTapWithError(inputNode, 0, 1024, format, tapBlock, &tapError)
        guard installed else {
            DebugLog.error("[AudioEngine] \(context): 装 tap 失败: \(tapError as String? ?? "unknown")")
            needsEngineRebuild = true
            return false
        }
        tapInstalled = true

        do {
            try engine.start()
            lastStartSucceededAt = Date()
            DebugLog.info("[AudioEngine] \(context): engine.start 成功")
            return true
        } catch {
            DebugLog.error("[AudioEngine] \(context): engine.start 抛异常 \(error)")
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            needsEngineRebuild = true
            return false
        }
    }

    func stop() {
        invalidateRouteRecovery()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        lastStartSucceededAt = nil
    }

    /// 路由恢复 watchdog 超时后使用：不要再同步触碰当前 AVAudioEngine。
    /// 它可能正卡在 CoreAudio 硬件查询里；这里只标脏，等待下一次 start() 新建实例。
    func abandonAfterRouteRecoveryFailure() {
        invalidateRouteRecovery()
        tapInstalled = false
        needsEngineRebuild = true
        lastStartSucceededAt = nil
        router.invalidate()
    }
}
