import Foundation

final class VolumeController {
    private var savedVolume: Int?
    private let decreaseRatio: Double = 0.2
    private let fadeDownDuration: TimeInterval = 0.3
    private let fadeUpDuration: TimeInterval = 0.5
    private var fadeTimer: Timer?

    private func getSystemVolume() -> Int? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "get output volume of (get volume settings)") else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return Int(result.int32Value)
    }

    private func setSystemVolume(_ volume: Int) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "set volume output volume \(volume)") else { return }
        script.executeAndReturnError(&error)
    }

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

    private func startFade(from startVol: Int, to targetVol: Int, duration: TimeInterval) {
        stopFade()

        let isDecreasing = startVol > targetVol

        func scheduleTimer() {
            let startTime = ProcessInfo.processInfo.systemUptime
            let start = Double(startVol)
            let target = Double(targetVol)

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

                let vol = Int(start + (target - start) * eased)
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
        let target = Int(Double(current) * decreaseRatio)
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
