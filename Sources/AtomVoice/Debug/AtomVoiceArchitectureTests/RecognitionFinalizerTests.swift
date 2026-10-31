import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum RecognitionFinalizerTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("A synchronous output callback starting another recording prevents old result hiding") {
            let harness = RecognitionFinalizerHarness()
            harness.sink.onDeliver = { harness.generation += 1 }
            harness.finish("old")
            try expect(harness.sink.deliveredTexts == ["old"])
            try expect(harness.presenter.events.isEmpty)
        }
        await runner.run("An empty live remainder hides immediately without waiting for its earlier paste") {
            let harness = RecognitionFinalizerHarness()
            var waitedForPriorOutput = false
            harness.finish("already sent", liveInsertion: .init(isActive: true, committedText: "already sent"),
                           waitForPriorOutput: { _ in waitedForPriorOutput = true })
            try expect(harness.sink.deliveredTexts.isEmpty)
            try expect(!waitedForPriorOutput)
            try expect(harness.presenter.events == ["dismissImmediately"])
        }
        await runner.run("Immediate punctuation hides after queuing and does not wait for prior output") {
            let harness = RecognitionFinalizerHarness()
            harness.sink.completesDeliveriesImmediately = false
            var waitedForPriorOutput = false
            harness.finish("", mode: .immediate(appending: "?"),
                           waitForPriorOutput: { _ in waitedForPriorOutput = true })
            try expect(harness.sink.deliveredTexts == ["?"])
            try expect(harness.presenter.events == ["dismissImmediately"])
            try expect(!waitedForPriorOutput)
        }
        await runner.run("Errors still wait for prior output and stale errors cannot reopen a newer capsule") {
            let harness = RecognitionFinalizerHarness()
            var finishPriorOutput: (() -> Void)?
            harness.finish("", errorMessage: "No speech", waitForPriorOutput: { finishPriorOutput = $0 })
            try expect(harness.presenter.events.isEmpty)
            try expect(finishPriorOutput != nil)
            harness.generation += 1
            finishPriorOutput?()
            try expect(harness.presenter.events.isEmpty)
        }
        await runner.run("Finalizer queues text before immediately hiding without waiting for cleanup") {
            let harness = RecognitionFinalizerHarness()
            harness.sink.completesDeliveriesImmediately = false
            var queuedBeforeHide = false
            harness.presenter.onDismissImmediately = {
                queuedBeforeHide = harness.sink.deliveredTexts == ["hello"]
            }
            harness.finish("hello")
            try expect(harness.sink.deliveredTexts == ["hello"])
            try expect(queuedBeforeHide)
            try expect(harness.presenter.events == ["dismissImmediately"])
            try expect(harness.sink.pendingDeliveryCompletions.count == 1)
            harness.sink.completeNextDelivery()
            try expect(harness.presenter.events == ["dismissImmediately"])
        }
        await runner.run("Old paste completion cannot dismiss a newer recording presentation") {
            let harness = RecognitionFinalizerHarness()
            harness.sink.completesDeliveriesImmediately = false
            harness.finish("old")
            harness.generation += 1
            harness.sink.completeNextDelivery()
            try expect(harness.presenter.events == ["dismissImmediately"])
        }
        await runner.run("LLM stays visible until its result then hides without the saved display delay") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 2
            harness.refiner.delayCompletion = true
            harness.finish("hello")
            try expect(harness.presenter.events == ["refining"])
            try expect(harness.sink.deliveredTexts.isEmpty)
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts == ["polished"], "Display delay must not postpone output")
            try expect(harness.presenter.events.last == "dismissImmediately")
            harness.generation += 1
            let events = harness.presenter.events
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts == ["polished"])
            try expect(harness.presenter.events == events)
        }
        await runner.run("LLM result hides before a slower paste transaction finishes") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 2
            harness.refiner.nextResult = "polished"
            harness.sink.completesDeliveriesImmediately = false
            harness.finish("hello")
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts == ["polished"])
            try expect(harness.presenter.events.last == "dismissImmediately")
            let events = harness.presenter.events
            harness.sink.completeNextDelivery()
            try expect(harness.presenter.events == events)
        }
        await runner.run("Finalizer preserves immediate mode without punctuation") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.finish("hello", mode: .immediate(appending: nil))
            try expect(harness.refiner.requests.isEmpty)
            try expect(harness.sink.deliveredTexts == ["hello"])
        }
        await runner.run("Finalizer waits for stream finalization then immediately hides without display delay") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmResultDelay = 2
            let stream = FakeTextStreamSession()
            stream.completesFinalizationImmediately = false
            harness.finish("hello", streamSession: stream)
            try expect(stream.finalizedReplacements.count == 1)
            try expect(harness.presenter.events.isEmpty)
            try expect(harness.clearedStreamCount == 0)
            try expect(stream.cancelCount == 0)
            stream.completeFinalization()
            try expect(harness.presenter.events == ["dismissImmediately"])
            try expect(harness.clearedStreamCount == 1)
        }
        await runner.run("Old streaming completion cannot clear a newer session or presentation") {
            let harness = RecognitionFinalizerHarness()
            let stream = FakeTextStreamSession()
            stream.completesFinalizationImmediately = false
            harness.finish("hello", mode: .immediate(appending: nil), streamSession: stream)
            harness.generation += 1
            stream.completeFinalization()
            try expect(harness.presenter.events.isEmpty)
            try expect(harness.clearedStreamCount == 0)
        }
        await runner.run("LLM error remains in progress until fallback paste completes") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextError = "LLM failed"
            harness.sink.completesDeliveriesImmediately = false
            harness.finish("hello")
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts == ["hello"])
            try expect(harness.presenter.events == ["refining"])
            harness.sink.completeNextDelivery()
            try expect(harness.presenter.events == ["refining", "error:LLM failed:3.0"])
        }
        await runner.run("Text processor registry stops at first handler") {
            let first = FakeTextProcessor(id: "first", output: nil)
            let second = FakeTextProcessor(id: "second", output: "handled")
            let third = FakeTextProcessor(id: "third", output: "late")
            let registry = TextPostProcessorRegistry(processors: [first, second, third])
            let context = TextProcessingContext(
                engineCode: ASREngineRegistry.appleCode,
                language: "en-US",
                isImmediateFinish: false
            )

            try expect(registry.run("raw", context: context) == "handled")
            try expect(first.callCount == 1)
            try expect(second.callCount == 1)
            try expect(third.callCount == 0)
        }
        await runner.run("Recognition finalizer delivers processed paste text") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])

            harness.finish("hello")

            try expect(harness.presenter.events == ["update:hello.", "dismissImmediately"])
            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(processor.lastContext?.isImmediateFinish == false)
        }
        await runner.run("Recognition finalizer replaces streaming text when punctuation changes") {
            let stream = FakeTextStreamSession()
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])

            harness.finish("hello", streamSession: stream)

            try expect(harness.presenter.events == ["update:hello.", "dismissImmediately"])
            try expect(stream.finalizedReplacements == ["hello."])
            try expect(stream.cancelCount == 0)
            try expect(harness.clearedStreamCount == 1)
        }
        await runner.run("Recognition finalizer appends immediate punctuation without LLM") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextResult = "HELLO"

            harness.finish("hello", mode: .immediate(appending: "?"))

            try expect(harness.refiner.requests.isEmpty)
            try expect(harness.sink.deliveredTexts == ["hello?"])
            try expect(processor.lastContext?.isImmediateFinish == true)
        }
        await runner.run("Recognition finalizer runs LLM for paste output") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextProgress = "pol"
            harness.refiner.nextResult = "polished."

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "update:pol", "update:polished.", "dismissImmediately"])
            try expect(harness.sink.deliveredTexts == ["polished."])
        }
        await runner.run("Recognition finalizer delivers processed text when LLM fails") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextError = "LLM failed"

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "error:LLM failed:3.0"])
        }
        await runner.run("Recognition finalizer handles empty text error fallback") {
            let harness = RecognitionFinalizerHarness()
            let stream = FakeTextStreamSession()

            harness.finish("", errorMessage: "No speech", streamSession: stream)

            try expect(stream.cancelCount == 1)
            try expect(harness.clearedStreamCount == 1)
            try expect(harness.presenter.events == ["error:No speech:5.0"])
            try expect(harness.sink.deliveredTexts.isEmpty)
        }
        await runner.run("Recognition finalizer injects live insertion remainder") {
            let harness = RecognitionFinalizerHarness()

            harness.finish(
                "Hello world again",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello world")
            )

            try expect(harness.sink.deliveredTexts == ["again"])
        }
        await runner.run("Recognition finalizer keeps LLM for streaming after live insertion") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextResult = "world polished"
            let stream = FakeTextStreamSession()

            harness.finish(
                "Hello world",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello"),
                streamSession: stream
            )
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["world"])
            try expect(stream.finalizedReplacements == ["world polished"])
            try expect(harness.clearedStreamCount == 1)
        }
        await runner.run("Recognition finalizer computes live insertion remainder") {
            let harness = RecognitionFinalizerHarness()

            try expect(
                harness.remainingText(
                    "Hello world again",
                    committedText: "Hello world"
                ) == "again"
            )
            try expect(
                harness.remainingText(
                    "Hello world again",
                    committedText: "Hello world "
                ) == "again"
            )
            try expect(
                harness.remainingText(
                    "Hello brave world",
                    committedText: "Hello basic"
                ) == "brave world"
            )
            try expect(
                harness.remainingText(
                    "Unrelated final",
                    committedText: "Hello"
                ) == "Unrelated final"
            )
        }
        await runner.run("Doubao fallback rolling look-back caps at window") {
            let coordinator = DoubaoFallbackCoordinator()
            let format = try require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            func makeBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                return buffer
            }
            // 16 个 0.5s buffer = 8s 输入；回看窗口 5s，应只保留最近 10 个(=5s)。
            for _ in 0..<16 {
                coordinator.captureAudioBuffer(makeBuffer(frames: 8000), copyBuffer: { $0 })
            }
            let snapshot = coordinator.rollingBufferSnapshot()
            let totalFrames = snapshot.reduce(0) { $0 + Int($1.frameLength) }
            try expect(snapshot.count == 10)
            try expect(totalFrames == 80000)
        }
        await runner.run("Cloud fallback text merge removes overlap") {
            let merged = DoubaoFallbackCoordinator.combinedText(
                prefix: "hello world",
                cachedText: "world from cache",
                liveText: "cache again"
            )

            try expect(merged == "hello world from cache again")
        }
        await runner.run("Cloud fallback text merge handles spacing and CJK") {
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "hello",
                    cachedText: "there",
                    liveText: ""
                ) == "hello there"
            )
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "你好",
                    cachedText: "世界",
                    liveText: ""
                ) == "你好世界"
            )
            try expect(
                DoubaoFallbackCoordinator.combinedText(
                    prefix: "hello.",
                    cachedText: "world",
                    liveText: ""
                ) == "hello. world"
            )
        }
        await runner.run("Apple speech rolling merge inserts Latin spacing") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "this is a test"
            )

            try expect(merged == "hello world this is a test")
        }
        await runner.run("Apple speech rolling merge removes overlap") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "world again"
            )

            try expect(merged == "hello world again")
        }
        await runner.run("Apple speech rolling merge keeps CJK tight") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "你好世界",
                segment: "继续说"
            )

            try expect(merged == "你好世界继续说")
        }
        await runner.run("Apple live insertion adapter commits only stable segments") {
            let adapter = AppleLiveInsertionAdapter()

            let first = try require(
                adapter.nextCommitDecision(
                    latestPartial: "hello. wor",
                    committedText: "",
                    isFinal: false
                )
            )
            try expect(first == AppleLiveSegmentDecision(segment: "hello. ", updatedCommittedText: "hello. "))

            try expect(
                adapter.nextCommitDecision(
                    latestPartial: "hello. wo",
                    committedText: "",
                    isFinal: false
                ) == nil
            )

            let final = try require(
                adapter.nextCommitDecision(
                    latestPartial: "hello.",
                    committedText: "",
                    isFinal: true
                )
            )
            try expect(final == AppleLiveSegmentDecision(segment: "hello.", updatedCommittedText: "hello."))

            try expect(
                adapter.nextCommitDecision(
                    latestPartial: "hello world. next",
                    committedText: "hello wor",
                    isFinal: false
                ) == nil
            )
        }
        await runner.run("Recognition finalizer ignores LLM results from old generation") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            
            harness.refiner.delayCompletion = true
            harness.generation = 10
            
            harness.finish("hello")
            
            // Verify refiner is called and refining state is true
            try expect(harness.refiner.requests == ["hello"])
            try expect(harness.isRefining == true)
            try expect(harness.presenter.events == ["refining"])
            
            // Advance generation to 11 (simulating cancellation/restarting a session)
            harness.generation = 11
            
            // Fire the delayed completion callbacks for generation 10
            harness.refiner.pendingOnProgress?("progress")
            
            // Trigger completion on main queue since completion executes inside DispatchQueue.main.async block
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            // Verify that the old generation's progress/completion results were completely ignored!
            // No new presenter events and no text delivered to sink!
            try expect(harness.presenter.events == ["refining"]) // remains unchanged, no "update:progress" or "update:polished"
            try expect(harness.sink.deliveredTexts.isEmpty)
        }
        await runner.run("Recognition finalizer updates refining state correctly") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.delayCompletion = true
            
            harness.generation = 1
            harness.finish("hello")
            
            try expect(harness.isRefining == true)
            
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            try expect(harness.isRefining == false)
            try expect(harness.sink.deliveredTexts == ["polished"])
        }
    }
}
