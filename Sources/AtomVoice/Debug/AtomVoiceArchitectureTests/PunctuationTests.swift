import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum PunctuationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Punctuation processor adds language-aware endings") {
            try expect(PunctuationProcessor.process("你好世界", language: "zh-CN") == "你好世界。")
            try expect(PunctuationProcessor.process("你好吗", language: "zh-CN") == "你好吗？")
            try expect(PunctuationProcessor.process("what time is it", language: "en-US") == "what time is it?")
            try expect(PunctuationProcessor.process("wow this works", language: "en-US") == "wow this works!")
            try expect(PunctuationProcessor.process("hello.", language: "en-US") == "hello.")
        }
        await runner.run("Punctuation detector exposes CJK and Latin decisions") {
            try expect(PunctuationProcessor.detectCJKPunctuation("可以吗", language: "zh-CN") == "？")
            try expect(PunctuationProcessor.detectCJKPunctuation("太好了", language: "zh-CN") == "！")
            try expect(PunctuationProcessor.detectCJKPunctuation("文件等等", language: "zh-CN") == "……")
            try expect(PunctuationProcessor.detectLatinPunctuation("is this ready", language: "en-US") == "?")
            try expect(PunctuationProcessor.detectLatinPunctuation("this is perfect", language: "en-US") == "!")
            try expect(PunctuationProcessor.detectLatinPunctuation("this is ready", language: "en-US") == ".")
        }
    }
}
