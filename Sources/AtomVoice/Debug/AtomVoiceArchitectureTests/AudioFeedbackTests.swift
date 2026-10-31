import AVFoundation
import Foundation
@testable import AtomVoiceCore

/// 使用真实分析器与合成 PCM 验证接线，不打开音频设备或创建窗口。
enum AudioFeedbackTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Production audio evidence protects steady low and soft voiced sounds") {
            for frequency in [85.0, 160.0, 250.0] {
                for rmsDB in [-35.0, -50.0, -55.0] {
                    let amplitude = pow(10, rmsDB / 20) * sqrt(2)
                    let frames = try await analyze(tone(frequency, amplitude: amplitude, count: 8192))
                    let voiced = frames.filter(\.isVoiceLike).count
                    try expect(voiced == frames.count, "Sustained tone \(frequency) Hz / \(rmsDB) dB should protect recording")
                }
            }
        }
        await runner.run("Production audio evidence rejects silence broadband noise and isolated clicks") {
            let count = 8192
            var random: UInt64 = 0x84ae
            let noise: [Float] = (0..<count).map { _ in
                random = random &* 6364136223846793005 &+ 1
                return Float(Double((random >> 32) & 0xffff) / 32767.5 - 1) * 0.08
            }
            var clicks = [Float](repeating: 0, count: count)
            for index in stride(from: 512, to: count, by: 1600) { clicks[index] = 0.8 }
            for samples in [[Float](repeating: 0, count: count), noise, clicks,
                            tone(60, amplitude: 0.04, count: count)] {
                let frames = try await analyze(samples)
                try expect(frames.allSatisfy { !$0.isVoiceLike }, "Non-voiced fixtures must not reset the full silence duration")
            }
            // 极低声音和周期性机器声是启发式的已知边界，不把它们伪装成已解决。
            let veryQuiet = try await analyze(tone(160, amplitude: 0.0002, count: count))
            let tonalMachine = try await analyze(tone(160, amplitude: 0.04, count: count))
            try expect(veryQuiet.allSatisfy { !$0.isVoiceLike })
            try expect(tonalMachine.allSatisfy(\.isVoiceLike))
        }
        await runner.run("Production audio frames retain capture timestamps across worker batching") {
            let frames = try await analyze(tone(160, amplitude: 0.02, count: 4096), endTime: 100.256)
            try expect(frames.count == 7)
            try expect(approximatelyEqual(frames.first!.capturedAt, 100.064))
            try expect(approximatelyEqual(frames.last!.capturedAt, 100.256))
            for pair in zip(frames, frames.dropFirst()) {
                try expect(approximatelyEqual(pair.1.capturedAt - pair.0.capturedAt, 0.032))
            }
        }
        await runner.run("Production analyzer feeds the combined monitor without any recognized text") {
            let frames = try await analyze(tone(160, amplitude: 0.006, count: 32000), endTime: 102)
            var clock = 100.0
            var tick: (() -> Void)?
            var stops = 0
            let monitor = ASRSilenceMonitor(
                now: { clock },
                settings: { .init(enabled: true, manualStop: false, duration: 0.3) },
                scheduleTick: { _, action in tick = action; return {} },
                enqueueTimeout: { $0() }
            )
            monitor.onTimeout = { stops += 1 }
            monitor.start()
            for frame in frames {
                clock = frame.capturedAt + 1e-9
                monitor.noteVoiceActivity(isVoiceLike: frame.isVoiceLike, at: frame.capturedAt)
                tick?()
            }
            try expect(stops == 0, "A stable voiced sound must keep capture active without ASR text")
            clock = frames.last!.capturedAt + 0.31
            tick?()
            try expect(stops == 1, "The configured silence duration still ends capture after sound ceases")
            monitor.stop()
        }
        await runner.run("Capsule audio delivery coalesces queued frames and schedules the next batch") {
            var queued: [() -> Void] = []
            var received: [Double] = []
            let delivery = CapsuleAudioFrameDelivery(schedule: { queued.append($0) })
            for index in 1...8 {
                delivery.submit(.init(bands: [Float(index)], isVoiceLike: false, capturedAt: Double(index))) {
                    received.append($0.capturedAt)
                }
            }
            try expect(queued.count == 1)
            queued.removeFirst()()
            try expect(received == [8], "A stalled main thread should display the latest frame only")
            delivery.submit(.init(bands: [9], isVoiceLike: false, capturedAt: 9)) { received.append($0.capturedAt) }
            try expect(queued.count == 1)
            queued.removeFirst()()
            try expect(received == [8, 9])
        }
    }

    private static func tone(_ frequency: Double, amplitude: Double, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / 16000)) }
    }

    private static func analyze(_ samples: [Float], endTime: TimeInterval = 100) async throws -> [AudioAnalysisFrame] {
        let format = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                               channels: 1, interleaved: false))
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let analyzer = AudioAnalyzer()
        let expected = (samples.count - 1024) / 512 + 1
        let result: [AudioAnalysisFrame] = await withCheckedContinuation { continuation in
            var frames: [AudioAnalysisFrame] = []
            analyzer.onAnalysis = { frame in
                frames.append(frame)
                if frames.count == expected { continuation.resume(returning: frames) }
            }
            analyzer.accept(buffer, capturedAt: endTime)
        }
        return withExtendedLifetime(analyzer) { result }
    }
}
