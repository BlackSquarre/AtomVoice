import Cocoa
@testable import AtomVoiceCore

/// 仅使用内存文本与 fake AX；不查询真实输入框或触发辅助功能权限。
private final class FakeCursorPunctuationAccess: CursorPunctuationAccess {
    typealias Element = Int
    var source: NSString = "前文。后"
    var selections = [CFRange(location: 2, length: 0)]
    var focuses = [1]
    var forcedComposedRange: CFRange?
    var forcedString: String?
    var failAt: String?
    var onCall: ((String) -> Void)?
    private(set) var calls: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var queriedIndices: [Int] = []
    private(set) var queriedRanges: [CFRange] = []
    private(set) var processIDs: [pid_t] = []
    private var focusIndex = 0
    private var selectionIndex = 0

    func application(processID: pid_t) -> Int {
        calls.append("application")
        processIDs.append(processID)
        return 0
    }

    private func begin(_ call: String, timeout: TimeInterval) -> Bool {
        calls.append(call)
        timeouts.append(timeout)
        onCall?(call)
        return failAt != call
    }

    func focusedElement(in application: Int, timeout: TimeInterval) -> Int? {
        guard begin("focus", timeout: timeout) else { return nil }
        defer { focusIndex += 1 }
        return focuses[min(focusIndex, focuses.count - 1)]
    }

    func selectedRange(in element: Int, timeout: TimeInterval) -> CFRange? {
        guard begin("selection", timeout: timeout) else { return nil }
        defer { selectionIndex += 1 }
        return selections[min(selectionIndex, selections.count - 1)]
    }

    func composedRange(at index: Int, in element: Int, timeout: TimeInterval) -> CFRange? {
        queriedIndices.append(index)
        guard begin("range", timeout: timeout) else { return nil }
        if let forcedComposedRange { return forcedComposedRange }
        guard index >= 0, index < source.length else { return nil }
        let range = source.rangeOfComposedCharacterSequence(at: index)
        return CFRange(location: range.location, length: range.length)
    }

    func string(in range: CFRange, element: Int, timeout: TimeInterval) -> String? {
        queriedRanges.append(range)
        guard begin("string", timeout: timeout) else { return nil }
        if let forcedString { return forcedString }
        return source.substring(with: NSRange(location: range.location, length: range.length))
    }

    func sameElement(_ first: Int, _ second: Int) -> Bool { first == second }
}

enum CursorPunctuationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Cursor punctuation skips lookup unless the actual last character is punctuation") {
            for text in ["", "hello", "hello. ", "你好。\n", "hello,", ".\u{0301}"] {
                let access = FakeCursorPunctuationAccess()
                try expect(probe(text, access) == text)
                try expect(access.calls.isEmpty)
            }
            let access = FakeCursorPunctuationAccess()
            try expect(CursorPunctuationProbe.textForInsertion("hello.", targetPID: nil, access: access) == "hello.")
            try expect(access.calls.isEmpty)
        }
        await runner.run("Cursor punctuation preserves the existing suffix removal set without trimming whitespace") {
            for punctuation in [".", "!", "?", "。", "！", "？", "…", "⋯", "~", "～"] {
                let access = FakeCursorPunctuationAccess()
                access.source = punctuation as NSString
                access.selections = [CFRange(location: 0, length: 0)]
                try expect(probe("文本.?!～", access) == "文本")
                try expect(access.processIDs == [123])
            }
            try expect(probe("文本 。", FakeCursorPunctuationAccess()) == "文本 ")
            try expect(probe("。？！", FakeCursorPunctuationAccess()).isEmpty)
        }
        await runner.run("Cursor punctuation uses the UTF16 selection end after an emoji") {
            let access = FakeCursorPunctuationAccess()
            access.source = "😀选中。后"
            access.selections = [CFRange(location: 2, length: 2)]
            try expect(probe("替换?", access) == "替换")
            try expect(access.queriedIndices == [4], "Must inspect after the selected text, not at its start")
            try expect(access.queriedRanges.count == 1)
            try expect(access.queriedRanges[0].location == 4 && access.queriedRanges[0].length == 1)
        }
        await runner.run("Cursor punctuation keeps emoji and combined punctuation intact") {
            for suffix in ["😀", "👨‍👩‍👧", ".\u{0301}", "。\u{FE0F}", "e\u{0301}"] {
                let access = FakeCursorPunctuationAccess()
                access.source = suffix as NSString
                access.selections = [CFRange(location: 0, length: 0)]
                try expect(probe("输入。", access) == "输入。")
                try expect(access.queriedRanges.count == 1)
                try expect(access.queriedRanges.allSatisfy { $0.length == suffix.utf16.count })
            }
            let split = FakeCursorPunctuationAccess()
            split.source = "😀。"
            split.selections = [CFRange(location: 1, length: 0)]
            try expect(probe("输入。", split) == "输入。")
            try expect(split.queriedRanges.isEmpty, "A range beginning before the offset is ambiguous")
        }
        await runner.run("Cursor punctuation fails open at EOF and when local AX is unsupported") {
            let eof = FakeCursorPunctuationAccess()
            eof.selections = [CFRange(location: eof.source.length, length: 0)]
            try expect(probe("输入。", eof) == "输入。")
            try expect(eof.queriedRanges.isEmpty)
            for failedCall in ["focus", "selection", "range", "string"] {
                let access = FakeCursorPunctuationAccess()
                access.failAt = failedCall
                try expect(probe("输入。", access) == "输入。")
                try expect(access.calls.last == failedCall, "No fallback or retry is allowed after failure")
            }
        }
        await runner.run("Cursor punctuation rejects invalid or overflowing selection offsets") {
            for range in [CFRange(location: -1, length: 0), CFRange(location: 0, length: -1),
                          CFRange(location: NSNotFound, length: 0), CFRange(location: Int.max - 1, length: 2)] {
                let access = FakeCursorPunctuationAccess()
                access.selections = [range]
                try expect(probe("输入。", access) == "输入。")
                try expect(access.queriedIndices.isEmpty)
            }
        }
        await runner.run("Cursor punctuation bounds composed ranges and rejects malformed local strings") {
            for combiningCount in [15, 16] {
                let access = FakeCursorPunctuationAccess()
                access.source = ("." + String(repeating: "\u{0301}", count: combiningCount)) as NSString
                access.selections = [CFRange(location: 0, length: 0)]
                try expect(probe("输入。", access) == "输入。")
                try expect(access.queriedRanges.count == (combiningCount == 15 ? 1 : 0))
            }
            for range in [CFRange(location: 1, length: 1), CFRange(location: 2, length: 0),
                          CFRange(location: 2, length: -1), CFRange(location: 2, length: 17),
                          CFRange(location: 2, length: Int.max)] {
                let access = FakeCursorPunctuationAccess()
                access.forcedComposedRange = range
                try expect(probe("输入。", access) == "输入。")
                try expect(access.queriedRanges.isEmpty)
            }
            for value in ["", "。。", "😀"] {
                let access = FakeCursorPunctuationAccess()
                access.forcedString = value
                try expect(probe("输入。", access) == "输入。")
            }
        }
        await runner.run("Cursor punctuation abandons deduction when focus or selection changes") {
            let changedFocus = FakeCursorPunctuationAccess()
            changedFocus.focuses = [1, 2]
            try expect(probe("输入。", changedFocus) == "输入。")
            for changedRange in [CFRange(location: 1, length: 1), CFRange(location: 2, length: 1)] {
                let access = FakeCursorPunctuationAccess()
                access.selections.append(changedRange)
                try expect(probe("输入。", access) == "输入。")
            }
        }
        await runner.run("Cursor punctuation applies one total budget and rejects late responses") {
            let access = FakeCursorPunctuationAccess()
            var clock: TimeInterval = 10
            access.onCall = { _ in clock += 0.02 }
            let result = CursorPunctuationProbe.textForInsertion("输入。", targetPID: 123, access: access, now: { clock })
            try expect(result == "输入。")
            try expect(access.calls.count <= 6, "The next query must not restart the deadline")
            try expect(access.timeouts.allSatisfy { $0 > 0 && $0 <= 0.025 })

            let late = FakeCursorPunctuationAccess()
            var selectionCalls = 0
            clock = 10
            late.onCall = { call in
                if call == "selection" {
                    selectionCalls += 1
                    if selectionCalls == 2 { clock += 1 }
                }
            }
            try expect(CursorPunctuationProbe.textForInsertion("输入。", targetPID: 123, access: late,
                                                              now: { clock }) == "输入。")
        }
        await runner.run("Cursor punctuation rejects cancellation before and during an in-flight query") {
            let initial = FakeCursorPunctuationAccess()
            try expect(CursorPunctuationProbe.textForInsertion("输入。", targetPID: 123, access: initial,
                                                              isCancelled: { true }) == "输入。")
            try expect(initial.calls.isEmpty)
            let access = FakeCursorPunctuationAccess()
            var cancelled = false
            access.onCall = { call in if call == "string" { cancelled = true } }
            try expect(CursorPunctuationProbe.textForInsertion("输入。", targetPID: 123, access: access,
                                                              isCancelled: { cancelled }) == "输入。")
            try expect(access.calls.last == "string")
        }
        await runner.run("Cursor punctuation validates AX range value type without querying any application") {
            try expect(SystemCursorPunctuationAccess.decodeRange(nil) == nil)
            try expect(SystemCursorPunctuationAccess.decodeRange("wrong" as CFString) == nil)
            var point = CGPoint(x: 1, y: 2)
            let wrongType = AXValueCreate(.cgPoint, &point)
            try expect(SystemCursorPunctuationAccess.decodeRange(wrongType) == nil)
            var expected = CFRange(location: 2, length: 3)
            let decoded = try require(SystemCursorPunctuationAccess.decodeRange(AXValueCreate(.cfRange, &expected)))
            try expect(decoded.location == 2 && decoded.length == 3)
        }
    }

    private static func probe(_ text: String, _ access: FakeCursorPunctuationAccess) -> String {
        CursorPunctuationProbe.textForInsertion(text, targetPID: 123, access: access, now: { 10 })
    }
}
