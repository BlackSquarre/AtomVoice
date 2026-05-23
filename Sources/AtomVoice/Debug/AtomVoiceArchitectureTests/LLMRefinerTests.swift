import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum LLMRefinerTests {
    static func run(_ runner: inout TestRunner) async {
        func makeDataTask() -> URLSessionDataTask {
            URLSession.shared.dataTask(with: URL(string: "https://example.invalid/sse-test")!)
        }

        func feed(_ delegate: AtomVoiceCore.StreamDelegate, _ chunk: String) {
            delegate.urlSession(URLSession.shared, dataTask: makeDataTask(), didReceive: Data(chunk.utf8))
        }

        func complete(_ delegate: AtomVoiceCore.StreamDelegate) {
            delegate.urlSession(URLSession.shared, task: makeDataTask(), didCompleteWithError: nil)
        }

        await runner.run("LLM refiner builds provider endpoints") {
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1/chat") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.openai.com/v1/chat/completions/") == "https://api.openai.com/v1/chat/completions")
            try expect(LLMRefiner.buildURL(base: "https://api.anthropic.com/v1") == "https://api.anthropic.com/v1/messages")
            try expect(LLMRefiner.buildURL(base: "https://api.anthropic.com/v1/messages") == "https://api.anthropic.com/v1/messages")
            try expect(LLMRefiner.buildCompletionsURL(base: "https://example.com/api/") == "https://example.com/api/chat/completions")
        }
        await runner.run("LLM refiner finds trailing UTF-8 boundary") {
            let complete = Data("hello你".utf8)
            let cjkBytes = Array("你".utf8)
            let splitCJK = Data("hello".utf8) + Data(cjkBytes.prefix(2))
            let emojiBytes = Array("🙂".utf8)
            let splitEmoji = Data("hello".utf8) + Data(emojiBytes.prefix(3))

            try expect(LLMRefiner.validUTF8PrefixLength(complete) == complete.count)
            try expect(LLMRefiner.validUTF8PrefixLength(splitCJK) == 5)
            try expect(LLMRefiner.validUTF8PrefixLength(splitEmoji) == 5)
            try expect(LLMRefiner.validUTF8PrefixLength(Data([0xE4])) == 0)
        }
        await runner.run("LLM refiner parses SSE JSON split across chunks") {
            var progress: [String] = []
            let delegate = StreamDelegate(
                isAnthropic: false,
                onProgress: { progress.append($0) },
                onComplete: { _, _ in }
            )

            let first = #"data: {"choices":[{"delta":{"content":"hel"}}"#
            let second = #"]}"# + "\n"
            feed(delegate, first)
            try await waitForAsyncCallbacks()
            try expect(progress.isEmpty)

            feed(delegate, second)
            try await waitForAsyncCallbacks()

            try expect(progress == ["hel"])
        }
        await runner.run("LLM refiner ignores SSE chunks after cancel") {
            var progress: [String] = []
            let delegate = StreamDelegate(
                isAnthropic: false,
                onProgress: { progress.append($0) },
                onComplete: { _, _ in }
            )

            delegate.cancelled = true
            let event = #"data: {"choices":[{"delta":{"content":"ignored"}}]}"# + "\n"
            feed(delegate, event)
            try await waitForAsyncCallbacks()

            try expect(progress.isEmpty)
        }
        await runner.run("LLM refiner skips malformed SSE JSON") {
            var progress: [String] = []
            let delegate = StreamDelegate(
                isAnthropic: false,
                onProgress: { progress.append($0) },
                onComplete: { _, _ in }
            )

            feed(delegate, "data: {bad json}\n")
            let validEvent = #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n"
            feed(delegate, validEvent)
            try await waitForAsyncCallbacks()

            try expect(progress == ["ok"])
        }
        await runner.run("LLM refiner accumulates multi-chunk SSE result") {
            var progress: [String] = []
            var completionResult: String?
            var completionError: String?
            let delegate = StreamDelegate(
                isAnthropic: false,
                onProgress: { progress.append($0) },
                onComplete: { result, error in
                    completionResult = result
                    completionError = error
                }
            )

            for token in ["The", " quick", " brown", " fox", "."] {
                let event = #"data: {"choices":[{"delta":{"content":"\#(token)"}}]}"# + "\n"
                feed(delegate, event)
            }
            try await waitForAsyncCallbacks()
            complete(delegate)
            try await waitForAsyncCallbacks()

            try expect(progress == ["The", "The quick", "The quick brown", "The quick brown fox", "The quick brown fox."])
            try expect(completionResult == "The quick brown fox.")
            try expect(completionError == nil)
        }
    }
}
