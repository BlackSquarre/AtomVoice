import Foundation
@testable import AtomVoiceCore

private final class FakePartialTextUpdateScheduledTask: PartialTextUpdateScheduledTask {
    private let action: () -> Void
    private(set) var isCancelled = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else { return }
        action()
    }
}

private final class FakePartialTextUpdateScheduler: PartialTextUpdateScheduling {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var tasks: [FakePartialTextUpdateScheduledTask] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> PartialTextUpdateScheduledTask {
        scheduledDelays.append(delay)
        let task = FakePartialTextUpdateScheduledTask(action: action)
        tasks.append(task)
        return task
    }

    func fireNext() {
        guard !tasks.isEmpty else { return }
        let task = tasks.removeFirst()
        task.fire()
    }
}

enum RecordingSessionPresenterTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Partial text throttler coalesces updates during cooldown") {
            let scheduler = FakePartialTextUpdateScheduler()
            let throttler = PartialTextUpdateThrottler(interval: 1.0 / 30.0, scheduler: scheduler)
            var delivered: [String] = []

            throttler.submit("a") { delivered.append($0) }
            throttler.submit("ab") { delivered.append($0) }
            throttler.submit("abc") { delivered.append($0) }

            try expect(delivered == ["a"])
            try expect(scheduler.scheduledDelays.count == 1)

            scheduler.fireNext()

            try expect(delivered == ["a", "abc"])
            try expect(scheduler.scheduledDelays.count == 2)
        }

        await runner.run("Partial text throttler flush resets cooldown for next state change") {
            let scheduler = FakePartialTextUpdateScheduler()
            let throttler = PartialTextUpdateThrottler(interval: 1.0 / 30.0, scheduler: scheduler)
            var delivered: [String] = []

            throttler.submit("hello") { delivered.append($0) }
            throttler.submit("hello world") { delivered.append($0) }
            throttler.flush { delivered.append($0) }
            throttler.submit("fresh start") { delivered.append($0) }

            try expect(delivered == ["hello", "hello world", "fresh start"])
        }

        await runner.run("Partial text throttler flush without pending text still clears cooldown") {
            let scheduler = FakePartialTextUpdateScheduler()
            let throttler = PartialTextUpdateThrottler(interval: 1.0 / 30.0, scheduler: scheduler)
            var delivered: [String] = []

            throttler.submit("first") { delivered.append($0) }
            throttler.flush { delivered.append($0) }
            throttler.submit("second") { delivered.append($0) }

            try expect(delivered == ["first", "second"])
        }
    }
}
