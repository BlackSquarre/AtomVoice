import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum LLMRefinerTests {
    static func run(_ runner: inout TestRunner) async {
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
    }
}
