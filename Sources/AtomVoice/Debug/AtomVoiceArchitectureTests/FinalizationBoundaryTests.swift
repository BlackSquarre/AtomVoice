import Foundation
@testable import AtomVoiceCore

enum FinalizationBoundaryTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Async postprocess fixes language punctuation and LLM connection for the round") {
            let processor = DeferredProcessor()
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "fixture"
            harness.settings.value.llmConnection = .init(baseURL: "https://fixture.invalid/v1", apiKey: "fixture", model: "original")
            harness.settings.value.llmSystemPrompt = "original prompt"
            harness.finish("hello")
            harness.settings.language = "zh-CN"
            harness.settings.llmEnabled = false
            harness.settings.value.autoPunctuationEnabled = false
            harness.settings.value.llmConnection?.model = "changed"
            harness.settings.value.llmSystemPrompt = "changed prompt"
            try expect(processor.context?.language == "en-US")
            try expect(processor.context?.autoPunctuationEnabled == true)
            processor.complete?("hello.")
            try await waitForAsyncCallbacks()
            try expect(harness.refiner.configurations.first?.connection.model == "original")
            try expect(harness.refiner.configurations.first?.systemPrompt == "original prompt")
            try expect(harness.sink.deliveredTexts == ["hello."])
        }
        await runner.run("Old independent final output survives generation while presentation stays untouched") {
            let processor = DeferredProcessor()
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.finish("old", isOutputValid: { true })
            harness.generation += 1
            let events = harness.presenter.events
            processor.complete?("old processed")
            processor.complete?("duplicate")
            try expect(harness.sink.deliveredTexts == ["old processed"])
            try expect(harness.presenter.events == events)
        }
        await runner.run("Owned refinement interrupted by new recording delivers original once and ignores late SSE") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "fixture"
            harness.refiner.delayCompletion = true
            harness.finish("original", isOutputValid: { true })
            harness.generation += 1
            let events = harness.presenter.events
            harness.finalizer.finishPendingRefinement()
            harness.finalizer.finishPendingRefinement()
            harness.refiner.pendingOnProgress?("late partial")
            harness.refiner.pendingCompletion?("late result", nil)
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts == ["original"])
            try expect(harness.presenter.events == events)
        }
        await runner.run("Explicit cancel discards owned refinement without original fallback") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "fixture"
            harness.refiner.delayCompletion = true
            harness.finish("original", isOutputValid: { true })
            harness.finalizer.discardPendingRefinement()
            harness.finalizer.finishPendingRefinement()
            harness.refiner.pendingCompletion?("late result", nil)
            try await waitForAsyncCallbacks()
            try expect(harness.sink.deliveredTexts.isEmpty)
        }
        await runner.run("Finalization retains output sink across asynchronous processing") {
            let first = FakeTextOutputSink(code: "first")
            let second = FakeTextOutputSink(code: "second")
            var current: TextOutputSink = first
            let processor = DeferredProcessor()
            let finalizer = RecognitionResultFinalizer(presenter: FakeRecognitionPresenter(),
                refiner: FakeRecognitionRefiner(), textPostProcessorRegistry: .init(processors: [processor]),
                outputSinkProvider: { current }, settingsProvider: {
                    .init(language: "en-US", llmEnabled: false, llmAPIKey: "", llmResultDelay: 0)
                })
            finalizer.finish(.init(recognizedText: "fixture", errorMessage: nil, mode: .normal,
                engineCode: ASREngineRegistry.appleCode, liveInsertion: .init(isActive: false, committedText: ""),
                streamSession: nil, clearStreamSession: {}, generation: 0))
            current = second
            processor.complete?("fixture processed")
            try expect(first.deliveredTexts == ["fixture processed"] && second.deliveredTexts.isEmpty)
        }
        await runner.run("Stop snapshot refreshes live ledger when submission resolves before ASR final") {
            let harness = RecognitionFinalizerHarness()
            let ledger = LiveInsertionDelivery()
            ledger.begin("first ")
            let snapshot = RecognitionLiveInsertionSnapshot(isActive: true, committedText: "", delivery: ledger)
            ledger.resolve(.init(submission: .eventPosted, cleanup: .notNeeded))
            harness.finish("first tail", liveInsertion: snapshot)
            try expect(harness.sink.deliveredTexts == ["tail"])
        }
        await runner.run("Request codec preserves protocol auth URL prompt and model without network") {
            for base in ["https://fixture.invalid/v1", "https://api.anthropic.com/v1"] {
                let configuration = LLMRefinementConfiguration(connection: .init(baseURL: base, apiKey: "fixture", model: "model"), systemPrompt: "prompt")
                let request = try LLMRequestBuilder.refinement(text: "fixture", configuration: configuration)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try expect(body["model"] as? String == "model" && body["stream"] as? Bool == true)
                try expect(request.timeoutInterval == 30)
                if base.contains("anthropic.com") {
                    try expect(request.url?.path == "/v1/messages")
                    try expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture")
                    try expect(body["system"] as? String == "prompt")
                } else {
                    try expect(request.url?.path == "/v1/chat/completions")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
                }
            }
        }
    }
}

private final class DeferredProcessor: TextPostProcessor {
    let id = "deferred"
    var complete: ((String?) -> Void)?
    var context: TextProcessingContext?
    func tryProcess(_ text: String, context: TextProcessingContext) -> String? { nil }
    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void) {
        self.context = context
        complete = completion
    }
}
