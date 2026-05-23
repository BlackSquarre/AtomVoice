import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum RecognitionFinalizerTests {
    static func run(_ runner: inout TestRunner) async {
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

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(processor.lastContext?.isImmediateFinish == false)
        }
        await runner.run("Recognition finalizer replaces streaming text when punctuation changes") {
            let stream = FakeTextStreamSession()
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])

            harness.finish("hello", streamSession: stream)

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
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
            try expect(harness.presenter.events == ["update:hello.", "refining", "update:pol", "update:polished.", "dismiss"])
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
