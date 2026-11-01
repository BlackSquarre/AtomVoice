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
            #if arch(x86_64)
            let completionTimeout: TimeInterval = 1.5
            #else
            let completionTimeout: TimeInterval = 0.75
            #endif
            let preflightResult = await waitForAudioStartResult(
                results,
                key: "preflight",
                timeout: completionTimeout
            )
            try expect(preflightResult == true, "input preflight did not complete within \(completionTimeout)s")
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
            defer { engine.stop() }

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
            #if arch(x86_64)
            let completionTimeout: TimeInterval = 1.5
            #else
            let completionTimeout: TimeInterval = 0.75
            #endif
            let startResult = await waitForAudioStartResult(
                results,
                key: "start",
                timeout: completionTimeout
            )
            try expect(startResult == true, "audio start result was \(String(describing: startResult)) after waiting up to \(completionTimeout)s")
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

private func waitForAudioStartResult(
    _ results: AudioStartResults,
    key: String,
    timeout: TimeInterval
) async -> Bool? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let result = results.value(for: key) {
            return result
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return results.value(for: key)
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
