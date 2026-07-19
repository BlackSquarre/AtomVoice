import Foundation
@testable import AtomVoiceCore

enum PasteboardServiceTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Pasteboard snapshot timeout does not wait for blocked provider") {
            let access = BlockingPasteboardAccess()
            let service = SystemPasteboardService(access: access)
            let startedAt = Date()

            let firstResult = await service.capture(timeout: 0.02)
            let elapsed = Date().timeIntervalSince(startedAt)
            guard case .timedOut = firstResult else {
                throw TestFailure(file: #filePath, line: #line, message: "expected timeout")
            }
            try expect(elapsed < 0.2, "blocked provider should not hold the caller")

            let secondResult = await service.capture(timeout: 0.02)
            guard case .busy = secondResult else {
                throw TestFailure(file: #filePath, line: #line, message: "expected busy while old provider call is blocked")
            }

            access.releaseCapture()
            try await waitForAsyncCallbacks()
            try expect(access.captureCallCount == 1, "busy requests must not accumulate behind blocked work")
        }
    }
}

private final class BlockingPasteboardAccess: PasteboardAccessing, @unchecked Sendable {
    private let captureSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCaptureCallCount = 0

    var captureCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCaptureCallCount
    }

    func capture() -> PasteboardCaptureResult {
        lock.lock()
        storedCaptureCallCount += 1
        lock.unlock()
        captureSemaphore.wait()
        return .captured(.init(items: [], changeCount: 1))
    }

    func write(text: String, replacing snapshot: PasteboardSnapshot) -> PasteboardWriteResult {
        .failed
    }

    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) -> PasteboardRestoreResult {
        .failed
    }

    func releaseCapture() {
        captureSemaphore.signal()
    }
}
