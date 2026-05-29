import Foundation

/// ASR 文本从云端进入本地到胶囊显示的 DEBUG 延迟探针。
enum ASRLatencyProbe {
    static func beginServerText(_ text: String, isFinal: Bool) {
        #if DEBUG_BUILD
        let now = tick()
        let isMain = Thread.isMainThread
        queue.async {
            if eventsByText[text] != nil {
                markLocked(text, stage: "server_duplicate", isFinal: isFinal, now: now, isMain: isMain, terminal: false)
                return
            }

            nextID += 1
            let event = Event(id: nextID, isFinal: isFinal, started: now, last: now)
            eventsByText[text] = event
            orderedTexts.append(text)
            pruneLocked()
            DebugLog.info("[ASRLatency] id=\(event.id) stage=server_text total=0.0ms step=0.0ms final=\(isFinal) thread=\(threadName(isMain)) \(textSummary(text))")
        }
        #endif
    }

    static func mark(_ text: String, stage: String, isFinal: Bool) {
        #if DEBUG_BUILD
        let now = tick()
        let isMain = Thread.isMainThread
        queue.async {
            markLocked(text, stage: stage, isFinal: isFinal, now: now, isMain: isMain, terminal: false)
        }
        #endif
    }

    static func mark(_ text: String, stage: String) {
        #if DEBUG_BUILD
        let now = tick()
        let isMain = Thread.isMainThread
        queue.async {
            markLocked(text, stage: stage, isFinal: nil, now: now, isMain: isMain, terminal: false)
        }
        #endif
    }

    static func finish(_ text: String, stage: String, isFinal: Bool) {
        #if DEBUG_BUILD
        let now = tick()
        let isMain = Thread.isMainThread
        queue.async {
            markLocked(text, stage: stage, isFinal: isFinal, now: now, isMain: isMain, terminal: true)
        }
        #endif
    }

    static func finish(_ text: String, stage: String) {
        #if DEBUG_BUILD
        let now = tick()
        let isMain = Thread.isMainThread
        queue.async {
            markLocked(text, stage: stage, isFinal: nil, now: now, isMain: isMain, terminal: true)
        }
        #endif
    }

    #if DEBUG_BUILD
    private struct Event {
        let id: Int
        let isFinal: Bool
        let started: UInt64
        var last: UInt64
    }

    private static let queue = DispatchQueue(label: "com.atomvoice.asrLatencyProbe", qos: .utility)
    private static var nextID = 0
    private static var eventsByText: [String: Event] = [:]
    private static var orderedTexts: [String] = []
    private static let maxTrackedEvents = 64

    private static func tick() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func markLocked(
        _ text: String,
        stage: String,
        isFinal: Bool?,
        now: UInt64,
        isMain: Bool,
        terminal: Bool
    ) {
        guard var event = eventsByText[text] else {
            DebugLog.info("[ASRLatency] id=none stage=\(stage) final=\(finalDescription(isFinal)) thread=\(threadName(isMain)) \(textSummary(text))")
            return
        }

        let total = milliseconds(from: event.started, to: now)
        let step = milliseconds(from: event.last, to: now)
        event.last = now
        eventsByText[text] = event
        DebugLog.info("[ASRLatency] id=\(event.id) stage=\(stage) total=\(format(total))ms step=\(format(step))ms final=\(finalDescription(isFinal ?? event.isFinal)) thread=\(threadName(isMain)) \(textSummary(text))")

        if terminal {
            eventsByText.removeValue(forKey: text)
            orderedTexts.removeAll { $0 == text }
        }
    }

    private static func pruneLocked() {
        while orderedTexts.count > maxTrackedEvents {
            let oldText = orderedTexts.removeFirst()
            eventsByText.removeValue(forKey: oldText)
        }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func threadName(_ isMain: Bool) -> String {
        isMain ? "main" : "bg"
    }

    private static func finalDescription(_ isFinal: Bool?) -> String {
        guard let isFinal else { return "unknown" }
        return isFinal ? "true" : "false"
    }

    private static func textSummary(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let suffix = escaped.count > 18 ? String(escaped.suffix(18)) : escaped
        return "chars=\(text.count) suffix=\"\(suffix)\""
    }
    #endif
}
