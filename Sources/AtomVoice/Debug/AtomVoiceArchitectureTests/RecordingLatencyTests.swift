import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum RecordingLatencyTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Buffered input preserves first samples and serializes live handoff") {
            let input = RecordingAudioInput()
            let values = LockedRecordingValues()
            let first = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.1))
            input.accept(first)
            first.floatChannelData?[0][0] = 0.9
            input.connect { buffer in values.append(buffer.floatChannelData![0][0]) }
            let second = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.2))
            input.accept(second)
            input.seal()
            input.accept(first)
            await withCheckedContinuation { continuation in
                input.finish { continuation.resume() }
            }
            try expect(values.snapshot.count == 2)
            try expect(approximatelyEqual(values.snapshot[0], 0.1))
            try expect(approximatelyEqual(values.snapshot[1], 0.2))
        }
        await runner.run("Release before recognizer readiness preserves buffered audio") {
            let input = RecordingAudioInput()
            let values = LockedRecordingValues()
            input.accept(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.3)))
            input.seal()
            input.connect { values.append($0.floatChannelData![0][0]) }
            await withCheckedContinuation { continuation in input.finish { continuation.resume() } }
            try expect(values.snapshot.count == 1)
        }
        await runner.run("Cancelled input cannot replay into a later session") {
            let input = RecordingAudioInput()
            let values = LockedRecordingValues()
            input.accept(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.4)))
            input.cancel()
            input.connect { values.append($0.floatChannelData![0][0]) }
            await withCheckedContinuation { continuation in input.finish { continuation.resume() } }
            try expect(values.snapshot.isEmpty)
        }
        await runner.run("Sherpa model preparation and final decoding never block main queue") {
            let runtime = BlockingSherpaRuntime()
            let engine = SherpaOnnxASREngine(recognizer: runtime)
            let startTime = ProcessInfo.processInfo.systemUptime
            let heartbeat = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    engine.startAsync(onResult: { _, _ in }) { _ in }
                    engine.stop { _, _ in }
                    DispatchQueue.main.async { continuation.resume(returning: ProcessInfo.processInfo.systemUptime) }
                }
            }
            try expect(heartbeat - startTime < 0.15, "runtime work blocked UI heartbeat")
            let text: String? = await withCheckedContinuation { continuation in
                engine.punctuateAsync("hello") { continuation.resume(returning: $0) }
            }
            try expect(text == "hello.")
            try expect(runtime.events == ["start", "finish", "punctuate"])
        }
        await runner.run("Sherpa cancel skips final decoding and serializes new model start") {
            let runtime = BlockingSherpaRuntime()
            let engine = SherpaOnnxASREngine(recognizer: runtime)
            engine.cancel()
            await withCheckedContinuation { continuation in
                engine.startAsync(onResult: { _, _ in }) { _ in continuation.resume() }
            }
            try expect(runtime.events == ["cancel", "start"])
        }
        await runner.run("Old Sherpa audio consumer cannot feed a newly started session") {
            let runtime = BlockingSherpaRuntime()
            let engine = SherpaOnnxASREngine(recognizer: runtime)
            let oldConsumer = engine.audioConsumer()
            engine.cancel()
            await withCheckedContinuation { continuation in
                engine.startAsync(onResult: { _, _ in }) { _ in continuation.resume() }
            }
            oldConsumer(try require(makePCMBuffer(sampleRate: 16_000, frameLength: 16, fillValue: 0.2)))
            await withCheckedContinuation { continuation in engine.stop { _, _ in continuation.resume() } }
            try expect(runtime.events == ["cancel", "start", "finish"])
        }
        await runner.run("Sherpa asynchronous punctuation rejects a superseded final without UI changes") {
            let processor = DelayedPunctuationProcessor()
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.finish("old", engineCode: ASREngineRegistry.sherpaCode)
            try expect(harness.sink.deliveredTexts.isEmpty)
            harness.generation += 1
            processor.completion?("old.")
            try expect(harness.sink.deliveredTexts.isEmpty)
            try expect(harness.presenter.events.isEmpty)
        }
        await runner.run("New recording invalidates old final during input startup") {
            var state = RecordingSessionState()
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            step(&state, .startValidated(engine: ASREngineRegistry.sherpaCode, lowerVolume: false))
            let first = state.recordingGeneration
            step(&state, .triggerReleased)
            step(&state, .triggerPressed(deferCapsulePresentation: false))
            try expect(state.isStarting)
            try expect(state.recordingGeneration != first)
        }
    }
}

private final class LockedRecordingValues {
    private let lock = NSLock()
    private var values: [Float] = []
    func append(_ value: Float) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Float] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class BlockingSherpaRuntime: SherpaRecognitionRuntime {
    var currentText: String { "hello" }
    var isModelLoaded: Bool { false }
    var lastStartFailureKind: SherpaOnnxStartFailureKind? { nil }
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recordedEvents }
    private func record(_ event: String) {
        lock.lock(); recordedEvents.append(event); lock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
    }
    func start(onResult: @escaping (String, Bool) -> Void) -> String? { record("start"); return nil }
    func accept(buffer: AVAudioPCMBuffer) { record("audio") }
    func stop() -> String { record("finish"); return "hello" }
    func invalidatePendingAudio() {}
    func cancel() { record("cancel") }
    func releaseModels() { record("release") }
    func punctuate(_ text: String) -> String? { record("punctuate"); return text + "." }
}

private final class DelayedPunctuationProcessor: TextPostProcessor {
    let id = "delayed"
    var completion: ((String?) -> Void)?
    func tryProcess(_ text: String, context: TextProcessingContext) -> String? { nil }
    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void) {
        self.completion = completion
    }
}
