import Foundation
@testable import AtomVoiceCore

private final class SilenceMonitorHarness {
    var time: TimeInterval = 100
    var settings = ASRSilenceMonitor.Settings(enabled: true, manualStop: false, duration: 3)
    var ticks: [() -> Void] = []
    var deliveries: [() -> Void] = []
    var timeoutCount = 0

    lazy var monitor: ASRSilenceMonitor = {
        let monitor = ASRSilenceMonitor(
            now: { [unowned self] in time },
            settings: { [unowned self] in settings },
            scheduleTick: { [unowned self] _, action in
                ticks.append(action)
                return {}
            },
            enqueueTimeout: { [unowned self] action in deliveries.append(action) }
        )
        monitor.onTimeout = { [unowned self] in timeoutCount += 1 }
        return monitor
    }()

    func tick() { ticks.last?() }

    func deliver() {
        let pending = deliveries
        deliveries.removeAll()
        pending.forEach { $0() }
    }

    func voice(_ value: Bool, advance: Double = 0.032) {
        time += advance
        monitor.noteVoiceActivity(isVoiceLike: value, at: time)
    }
}

enum ASRSilenceMonitorTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Production silence monitor preserves configured duration and fires once") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 2.9
            h.tick()
            try expect(h.deliveries.isEmpty)
            h.time += 0.2
            h.tick()
            h.tick()
            try expect(h.deliveries.count == 1)
            h.deliver()
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor preserves its initial guard period") {
            let h = SilenceMonitorHarness()
            h.settings.duration = 0.3
            h.monitor.start()
            h.time += 0.4
            h.tick()
            try expect(h.deliveries.isEmpty)
            h.time += 0.2
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor stop and restart invalidate queued timeouts") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 4
            h.tick()
            let oldTick = h.ticks[0]
            h.monitor.stop()
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.monitor.start()
            h.time += 4
            oldTick()
            try expect(h.deliveries.isEmpty)
            h.tick()
            h.monitor.start()
            h.time += 4
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor activity revision revokes an old proposal") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 3.1
            h.tick()
            h.monitor.noteText("继续说话")
            h.time += 4
            h.deliver()
            try expect(h.timeoutCount == 0, "Old proposal must not commit even if its replacement window later expires")
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor accepts growing ASR text after prefix revisions") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 2
            h.monitor.noteText("今天去北京")
            h.time += 2
            h.monitor.noteText("明天去上海出差")
            h.time += 2
            h.tick()
            try expect(h.deliveries.isEmpty)
            h.time += 1.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor accepts new same-length revisions but not oscillation") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 2
            h.monitor.noteText("今天北京")
            h.time += 2
            h.monitor.noteText("明天上海")
            h.time += 2
            h.tick()
            try expect(h.deliveries.isEmpty)
            h.monitor.noteText("今天北京")
            h.time += 0.5
            h.monitor.noteText("明天上海")
            h.time += 0.6
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor ignores punctuation duplicates and recognition rollback") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 1
            h.monitor.noteText("hello world")
            for text in ["Hello, world!", "hello", "hello world", "hello world… ", "hello world… "] {
                h.time += 0.5
                h.monitor.noteText(text)
            }
            h.time = 104.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor preserves genuine untimed growth without acoustic evidence") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            for count in 1...10 {
                h.time += 1
                h.monitor.noteText(String(repeating: "字", count: count))
                h.tick()
                h.deliver()
            }
            try expect(h.timeoutCount == 0)
            h.time += 3.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor preserves sustained voice without recognized text") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            for _ in 0..<250 {
                h.voice(true)
                h.tick()
                h.deliver()
            }
            try expect(h.timeoutCount == 0)
            h.voice(false)
            h.time += 3.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor rejects isolated transient and sparse voice evidence") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            for _ in 0..<40 {
                h.voice(true, advance: 0.04)
                h.voice(false, advance: 0.04)
                h.tick()
                h.deliver()
            }
            try expect(h.timeoutCount == 1)
            h.monitor.start()
            for _ in 0..<16 { h.voice(true, advance: 0.2) }
            h.tick()
            h.deliver()
            h.time += 0.13
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 2, "Separated observations may get brief confirmation, but must not renew the full silence window")
        }
        await runner.run("Production silence monitor handles equal buffer timestamps conservatively") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.voice(true, advance: 0.1)
            h.monitor.noteVoiceActivity(isVoiceLike: false, at: h.time)
            h.voice(true, advance: 0.064)
            h.time = 103.01
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1, "Quiet FFT window sharing the buffer timestamp must break the voice run")
        }
        await runner.run("Production silence monitor protects voice starting just before the deadline") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time = 102.99
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.time = 103
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time = 103.022
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.time = 103.054
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.time = 103.2
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time = 106.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor expires a lone candidate without granting a full silence window") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time = 102.99
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.time = 103
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time = 103.12
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor does not repeatedly extend candidate confirmation") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time = 103
            h.tick()
            h.time = 103.01
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.deliver()
            try expect(h.timeoutCount == 0, "Candidate arriving before main delivery must revoke the proposal")
            h.time = 103.2
            h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time)
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1, "Another isolated onset must not restart the expired confirmation budget")
        }
        await runner.run("Production silence monitor rechecks confirmed voice before timeout delivery") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 3.1
            h.tick()
            for _ in 0..<3 { h.voice(true) }
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time += 3.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor rejects old-session future and out-of-order audio") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 4
            let oldTime = h.time
            h.monitor.stop()
            h.time += 1
            h.monitor.start()
            for offset in [0.0, 0.032, 0.064] {
                h.monitor.noteVoiceActivity(isVoiceLike: true, at: oldTime + offset)
                h.monitor.noteVoiceActivity(isVoiceLike: true, at: h.time + 10 + offset)
            }
            h.time += 3.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
            h.monitor.start()
            h.voice(true)
            h.voice(true)
            h.monitor.noteVoiceActivity(isVoiceLike: false, at: h.time - 0.01)
            h.voice(true)
            h.time += 2.99
            h.tick()
            try expect(h.deliveries.isEmpty, "Old quiet observation must not erase a newer voice run")
        }
        await runner.run("Production silence monitor keeps fallback grace and rechecks it before delivery") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 3.1
            h.tick()
            h.monitor.extendTimeout(by: 5)
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time += 4
            h.tick()
            try expect(h.deliveries.isEmpty)
            h.time += 1.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor rechecks manual disabled and duration settings") {
            let h = SilenceMonitorHarness()
            h.monitor.start()
            h.time += 4
            h.tick()
            h.settings.manualStop = true
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.settings.manualStop = false
            h.tick()
            h.settings.enabled = false
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.settings.enabled = true
            h.tick()
            h.settings.duration = 5
            h.deliver()
            try expect(h.timeoutCount == 0)
            h.time += 1.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
        await runner.run("Production silence monitor timeout callback may synchronously stop") {
            let h = SilenceMonitorHarness()
            h.monitor.onTimeout = {
                h.timeoutCount += 1
                h.monitor.stop()
            }
            defer { h.monitor.onTimeout = nil }
            h.monitor.start()
            h.time += 3.1
            h.tick()
            h.deliver()
            try expect(h.timeoutCount == 1)
        }
    }
}
