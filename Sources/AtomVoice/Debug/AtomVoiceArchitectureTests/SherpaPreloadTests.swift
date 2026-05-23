import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum SherpaPreloadTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Model manifest discovers nested files offline") {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let exp = root.appendingPathComponent("exp", isDirectory: true)
            let lang = root.appendingPathComponent("data/lang_char", isDirectory: true)
            try FileManager.default.createDirectory(at: exp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: lang, withIntermediateDirectories: true)

            try writeDummyFile(exp.appendingPathComponent("streaming-encoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-encoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-joiner-int8.onnx"))
            try writeDummyFile(lang.appendingPathComponent("tokens.txt"))

            let manifest = try require(ModelManifest.discover(in: root), "manifest should be discovered")

            try expect(manifest.encoder == "exp/streaming-encoder-int8.onnx")
            try expect(manifest.decoder == "exp/streaming-decoder.onnx")
            try expect(manifest.joiner == "exp/streaming-joiner-int8.onnx")
            try expect(manifest.tokens == "data/lang_char/tokens.txt")
            try expect(manifest.isComplete(in: root))
        }
        await runner.run("Sherpa preload drains buffered audio in order") {
            let coordinator = SherpaPreloadCoordinator()
            let first = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.1))
            let second = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.2))

            coordinator.begin()
            try expect(coordinator.appendIfActive(first) { $0 })
            try expect(coordinator.appendIfActive(second) { $0 })
            try await waitForAsyncCallbacks()

            var drained: [AVAudioPCMBuffer] = []
            var completed = false
            coordinator.drain(
                accept: { drained.append($0) },
                onComplete: { completed = true }
            )
            try await waitForAsyncCallbacks()

            try expect(completed)
            try expect(drained.count == 2)
            try expect(drained[0] === first)
            try expect(drained[1] === second)
            try expect(!coordinator.appendIfActive(first) { $0 })
        }
    }
}
