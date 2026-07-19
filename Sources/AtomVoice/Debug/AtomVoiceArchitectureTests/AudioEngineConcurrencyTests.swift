import Foundation
@preconcurrency @testable import AtomVoiceCore

enum AudioEngineConcurrencyTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Audio input preflight does not block main queue") {
            let results = AudioStartResults()
            let engine = AudioEngineController(
                inputReadinessOperationOverride: {
                    Thread.sleep(forTimeInterval: 0.25)
                    return true
                }
            )

            let startedAt = Date()
            let heartbeatDelay = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    engine.waitForInputReady(timeout: 0.5) { ready in
                        results.set("preflight", ready)
                    }
                    DispatchQueue.main.async {
                        continuation.resume(returning: Date().timeIntervalSince(startedAt))
                    }
                }
            }

            try expect(heartbeatDelay < 0.1, "main queue heartbeat was delayed by input preflight")
            try await Task.sleep(nanoseconds: 350_000_000)
            try expect(results.value(for: "preflight") == true)
        }

        await runner.run("Audio engine blocking start does not block main queue") {
            let results = AudioStartResults()
            let engine = AudioEngineController(
                startOperationOverride: {
                    Thread.sleep(forTimeInterval: 0.25)
                    return true
                },
                stopOperationOverride: {}
            )

            let startedAt = Date()
            let heartbeatDelay = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    engine.start { result in
                        results.set("start", result)
                    }
                    DispatchQueue.main.async {
                        continuation.resume(returning: Date().timeIntervalSince(startedAt))
                    }
                }
            }

            try expect(heartbeatDelay < 0.1, "main queue heartbeat was delayed by audio start")
            try await Task.sleep(nanoseconds: 350_000_000)
            try expect(results.value(for: "start") == true)
            engine.stop()
        }

        await runner.run("Audio engine stop invalidates a blocked start") {
            let operationStarted = DispatchSemaphore(value: 0)
            let releaseOperation = DispatchSemaphore(value: 0)
            let results = AudioStartResults()
            let engine = AudioEngineController(
                startOperationOverride: {
                    operationStarted.signal()
                    _ = releaseOperation.wait(timeout: .now() + 1)
                    return true
                },
                stopOperationOverride: {}
            )

            engine.start { result in
                results.set("start", result)
            }
            try expect(operationStarted.wait(timeout: .now() + 0.5) == .success)

            engine.stop()
            releaseOperation.signal()
            try await Task.sleep(nanoseconds: 120_000_000)

            try expect(results.value(for: "start") == false)
        }

        await runner.run("Stale audio start cannot override a newer start") {
            let firstStarted = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let callCounter = LockedCounter()
            let results = AudioStartResults()
            let engine = AudioEngineController(
                startOperationOverride: {
                    let call = callCounter.increment()
                    if call == 1 {
                        firstStarted.signal()
                        _ = releaseFirst.wait(timeout: .now() + 1)
                    }
                    return true
                },
                stopOperationOverride: {}
            )

            engine.start { result in
                results.set("first", result)
            }
            try expect(firstStarted.wait(timeout: .now() + 0.5) == .success)

            engine.stop()
            engine.start { result in
                results.set("second", result)
            }
            releaseFirst.signal()
            try await Task.sleep(nanoseconds: 180_000_000)

            try expect(results.value(for: "first") == false)
            try expect(results.value(for: "second") == true)
            engine.stop()
        }
    }
}

private final class AudioStartResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func set(_ key: String, _ value: Bool) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func value(for key: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
