import Foundation
import CoreAudio

final class VolumeController {
    private var savedVolume: Float?
    private let decreaseRatio: Float = 0.2
    private let fadeDownDuration: TimeInterval = 0.3
    private let fadeUpDuration: TimeInterval = 0.5
    private var fadeTimer: Timer?

    // MARK: - CoreAudio 音量控制

    /// 获取默认输出设备 ID（Get default output device ID）
    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// 获取系统音量（0.0–1.0）（Get system volume, 0.0–1.0）
    private func getSystemVolume() -> Float? {
        guard let deviceID = getDefaultOutputDevice() else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        // 先尝试主声道（element 0），不支持时尝试 element 1（Try main channel first, fall back to element 1）
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    /// 设置系统音量（0.0–1.0）（Set system volume, 0.0–1.0）
    private func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDevice() else { return }
        var vol = max(0, min(1, volume))
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            // 检查属性是否可设置（Check if property is settable）
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
                continue
            }
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
    }

    // MARK: - 渐变控制

    private func stopFade() {
        if Thread.isMainThread {
            fadeTimer?.invalidate()
            fadeTimer = nil
        } else {
            let timer = fadeTimer
            DispatchQueue.main.async { timer?.invalidate() }
            fadeTimer = nil
        }
    }

    private func startFade(from startVol: Float, to targetVol: Float, duration: TimeInterval) {
        stopFade()

        let isDecreasing = startVol > targetVol

        func scheduleTimer() {
            let startTime = ProcessInfo.processInfo.systemUptime

            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard self != nil else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(elapsed / duration, 1.0)

                let t = progress
                let eased: Double
                if isDecreasing {
                    // 降音量：easeOutCubic — 快速下降，缓停（Decrease volume: easeOutCubic — fast drop, gentle stop）
                    let inv = 1.0 - t
                    eased = 1.0 - inv * inv * inv
                } else {
                    // 升音量：easeInOutCubic — 平滑恢复（Increase volume: easeInOutCubic — smooth recovery）
                    if t < 0.5 {
                        eased = 4 * t * t * t
                    } else {
                        let inv = 1.0 - t
                        eased = 1.0 - 2 * inv * inv * inv
                    }
                }

                let vol = Float(Double(startVol) + Double(targetVol - startVol) * eased)
                self?.setSystemVolume(vol)

                if progress >= 1.0 {
                    timer.invalidate()
                    self?.fadeTimer = nil
                    self?.setSystemVolume(targetVol)
                }
            }
        }

        if Thread.isMainThread {
            scheduleTimer()
        } else {
            DispatchQueue.main.async { scheduleTimer() }
        }
    }

    func saveAndDecreaseVolume() {
        guard savedVolume == nil else { return } // 已经在降低/已降低状态，跳过重复调用
        guard let current = getSystemVolume() else { return }
        savedVolume = current
        let target = current * decreaseRatio
        startFade(from: current, to: target, duration: fadeDownDuration)
    }

    func restoreVolume() {
        guard let saved = savedVolume else { return }
        savedVolume = nil
        let current = getSystemVolume() ?? saved
        startFade(from: current, to: saved, duration: fadeUpDuration)
    }

    deinit {
        stopFade()
        if let saved = savedVolume {
            setSystemVolume(saved)
        }
    }
}
