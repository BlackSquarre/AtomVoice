#if DEBUG_BUILD
import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum DebugAudioEvidenceRecorderTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Debug audio evidence recorder writes recent buffers") {
            let directory = try makeTemporaryDirectory()
            let recorder = DebugAudioEvidenceRecorder(directory: directory, maxDuration: 2, maxFiles: 4)
            let buffer = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.5))

            recorder.record(buffer)
            let url = try require(recorder.preserve(reason: .sessionStartFailed))
            let file = try AVAudioFile(forReading: url)

            try expect(FileManager.default.fileExists(atPath: url.path))
            try expect(file.length == 160)
        }

        await runner.run("Debug audio evidence recorder keeps bounded evidence files") {
            let directory = try makeTemporaryDirectory()
            let recorder = DebugAudioEvidenceRecorder(directory: directory, maxDuration: 2, maxFiles: 1)
            let buffer = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 160, fillValue: 0.5))

            recorder.record(buffer)
            _ = try require(recorder.preserve(reason: .sessionStartFailed))
            _ = try require(recorder.preserve(reason: .audioRouteRecoveryFailed))

            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "caf" }
            try expect(files.count == 1)
        }
    }
}
#endif
