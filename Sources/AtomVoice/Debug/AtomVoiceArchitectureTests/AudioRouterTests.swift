import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum AudioRouterTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("ASR silence monitor fires when no text arrives within duration") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = false
            AppSettings.silenceDuration = 0.7

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            monitor.stop()

            try expect(timeoutCount >= 1)
        }
        await runner.run("ASR silence monitor keeps alive when text keeps growing") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = false
            AppSettings.silenceDuration = 0.5

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            // 每 200ms 喂一次新文本，silenceDuration=0.5s 永远不会到
            for i in 1...10 {
                try await Task.sleep(nanoseconds: 200_000_000)
                monitor.noteText("partial \(i)")
            }
            monitor.stop()

            try expect(timeoutCount == 0)
        }
        await runner.run("ASR silence monitor respects manual stop setting") {
            let oldAutoStop = AppSettings.silenceAutoStopEnabled
            let oldManualStop = AppSettings.tapModeManualStop
            let oldDuration = AppSettings.silenceDuration
            defer {
                AppSettings.silenceAutoStopEnabled = oldAutoStop
                AppSettings.tapModeManualStop = oldManualStop
                AppSettings.silenceDuration = oldDuration
            }

            AppSettings.silenceAutoStopEnabled = true
            AppSettings.tapModeManualStop = true
            AppSettings.silenceDuration = 0.3

            let monitor = ASRSilenceMonitor()
            var timeoutCount = 0
            monitor.onTimeout = { timeoutCount += 1 }

            monitor.start()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            monitor.stop()

            try expect(timeoutCount == 0)
        }
        await runner.run("Audio router unregisters native consumers") {
            let router = AudioRouter()
            let buffer = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 32), "buffer should be created")
            var firstCount = 0
            var secondCount = 0

            let firstID = router.register(format: nil) { received in
                if received === buffer { firstCount += 1 }
            }
            let secondID = router.register(format: nil) { received in
                if received === buffer { secondCount += 1 }
            }

            router.receive(buffer)
            router.unregister(firstID)
            router.receive(buffer)

            try expect(firstCount == 1)
            try expect(secondCount == 2)
            try expect(secondID != firstID)
        }
        await runner.run("Audio router shares converted buffer for matching target consumers") {
            let router = AudioRouter()
            let input = try require(makePCMBuffer(sampleRate: 48_000, frameLength: 480), "buffer should be created")
            var firstBuffer: AVAudioPCMBuffer?
            var secondBuffer: AVAudioPCMBuffer?

            _ = router.register(format: .voice16k) { firstBuffer = $0 }
            _ = router.register(format: .voice16k) { secondBuffer = $0 }

            router.receive(input)

            try expect(firstBuffer != nil)
            try expect(firstBuffer === secondBuffer)
            try expect(firstBuffer?.format.sampleRate == 16_000)
            try expect(firstBuffer?.format.channelCount == 1)
        }
    }
}
