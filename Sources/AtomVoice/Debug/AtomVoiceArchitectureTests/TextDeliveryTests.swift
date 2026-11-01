import AppKit
import Foundation
@testable import AtomVoiceCore

enum TextDeliveryTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Live delivery records only posted events and resolves once") {
            let delivery = LiveInsertionDelivery()
            delivery.begin("first")
            var resolved: [String] = []
            delivery.whenResolved { resolved.append($0) }
            try expect(delivery.committedText.isEmpty)
            try expect(delivery.resolve(.init(submission: .notSubmitted, cleanup: .notNeeded)))
            try expect(resolved == [""])
            try expect(!delivery.resolve(.init(submission: .eventPosted, cleanup: .completed)))
            delivery.begin("second")
            delivery.resolve(.init(submission: .eventPosted, cleanup: .failed))
            try expect(delivery.committedText == "second")
        }

        for capture in [PasteboardCaptureResult.busy, .changed, .timedOut] {
            await runner.run("Injection capture failure never posts or switches input source: \(capture)") {
                let platform = DeliveryPlatformFake()
                let pasteboard = DeliveryPasteboardFake()
                pasteboard.captureResult = capture
                let (result, submissions) = await inject(platform: platform, pasteboard: pasteboard)
                try expect(result == .init(submission: .notSubmitted, cleanup: .notNeeded))
                try expect(submissions == [.notSubmitted])
                try expect(platform.events.isEmpty)
                try expect(pasteboard.writeCount == 0)
            }
        }

        await runner.run("Injection target change after input switch restores input and clipboard once") {
            let platform = DeliveryPlatformFake()
            platform.changeTargetOnSwitch = true
            let pasteboard = DeliveryPasteboardFake()
            let (result, submissions) = await inject(platform: platform, pasteboard: pasteboard)
            try expect(result == .init(submission: .notSubmitted, cleanup: .completed))
            try expect(submissions == [.notSubmitted])
            try expect(platform.events == ["switch", "restore"])
            try expect(pasteboard.restoreCount == 1)
        }

        await runner.run("Posted event stays committed when cleanup fails and preserves read window") {
            let platform = DeliveryPlatformFake()
            let pasteboard = DeliveryPasteboardFake()
            pasteboard.restoreResult = .failed
            var waits: [Double] = []
            let (result, submissions) = await inject(platform: platform, pasteboard: pasteboard, sleep: { waits.append($0) })
            try expect(result == .init(submission: .eventPosted, cleanup: .failed))
            try expect(submissions == [.eventPosted])
            try expect(platform.events == ["switch", "post", "restore"])
            try expect(waits.count == 3 && waits[0] == 0.05 && waits[2] >= 0.75)
            try expect(pasteboard.restoreCount == 1)
        }

        await runner.run("Failed write reports failed rollback without another restore attempt") {
            let platform = DeliveryPlatformFake()
            let pasteboard = DeliveryPasteboardFake()
            pasteboard.writeResult = .failedAfterRollback(.failed)
            let (result, submissions) = await inject(platform: platform, pasteboard: pasteboard)
            try expect(result == .init(submission: .notSubmitted, cleanup: .failed))
            try expect(submissions == [.notSubmitted])
            try expect(pasteboard.restoreCount == 0 && platform.events.isEmpty)
        }

        await runner.run("Failed clipboard write never posts or switches input source") {
            let platform = DeliveryPlatformFake()
            let pasteboard = DeliveryPasteboardFake()
            pasteboard.writeResult = .failed
            let (result, _) = await inject(platform: platform, pasteboard: pasteboard)
            try expect(result.submission == .notSubmitted)
            try expect(platform.events.isEmpty)
        }
    }

    private static func inject(platform: DeliveryPlatformFake, pasteboard: DeliveryPasteboardFake,
                               sleep: @escaping (Double) async -> Void = { _ in }) async -> (TextDeliveryResult, [TextDeliverySubmission]) {
        let injector = TextInjector(pasteboardService: pasteboard, platform: platform, sleep: sleep)
        var submissions: [TextDeliverySubmission] = []
        let result: TextDeliveryResult = await withCheckedContinuation { continuation in
            injector.inject(text: "fixture", onSubmission: { submissions.append($0) }) {
                continuation.resume(returning: $0)
            }
        }
        return (result, submissions)
    }
}

private final class DeliveryPlatformFake: TextInjectionPlatform {
    var pid: pid_t? = 42
    var changeTargetOnSwitch = false
    var events: [String] = []
    func target() -> TextInjectionTarget { .init(processID: pid, bundleID: "fixture", profile: nil) }
    func frontmostProcessID() -> pid_t? { pid }
    func preparePaste(for target: TextInjectionTarget) async -> @MainActor () async -> TextDeliverySubmission {
        { MainActor.preconditionIsolated(); self.events.append("post"); return .eventPosted }
    }
    func textForInsertion(_ text: String, targetPID: pid_t?) async -> String { text }
    func prepareInputSource() -> TextInjectionInputSource {
        events.append("switch")
        if changeTargetOnSwitch { pid = 43 }
        return .init(needsSwitch: true, restore: { self.events.append("restore") })
    }
}

private final class DeliveryPasteboardFake: PasteboardServicing {
    var captureResult = PasteboardCaptureResult.captured(.init(items: [], changeCount: 1))
    var writeResult = PasteboardWriteResult.written(changeCount: 2)
    var restoreResult = PasteboardRestoreResult.restored
    var writeCount = 0
    var restoreCount = 0
    func capture(timeout: TimeInterval) async -> PasteboardCaptureResult { captureResult }
    func write(text: String, replacing snapshot: PasteboardSnapshot) async -> PasteboardWriteResult {
        writeCount += 1
        return writeResult
    }
    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) async -> PasteboardRestoreResult {
        restoreCount += 1
        return restoreResult
    }
}
