import AppKit
import Foundation

struct PasteboardSnapshot {
    struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let items: [[Entry]]
    let changeCount: Int
}

enum PasteboardCaptureResult {
    case captured(PasteboardSnapshot)
    case timedOut
    case busy
    case changed
}

enum PasteboardWriteResult {
    case written(changeCount: Int)
    case changed
    case failed
}

enum PasteboardRestoreResult {
    case restored
    case skippedChanged
    case failed
}

protocol PasteboardServicing: AnyObject {
    func capture(timeout: TimeInterval) async -> PasteboardCaptureResult
    func write(text: String, replacing snapshot: PasteboardSnapshot) async -> PasteboardWriteResult
    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) async -> PasteboardRestoreResult
}

protocol PasteboardAccessing: AnyObject {
    func capture() -> PasteboardCaptureResult
    func write(text: String, replacing snapshot: PasteboardSnapshot) -> PasteboardWriteResult
    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) -> PasteboardRestoreResult
}

final class SystemPasteboardService: PasteboardServicing, @unchecked Sendable {
    private let workerQueue = DispatchQueue(label: "com.blacksquarre.AtomVoice.pasteboard")
    private let timeoutQueue = DispatchQueue(label: "com.blacksquarre.AtomVoice.pasteboard-timeout")
    private let captureLock = NSLock()
    private var captureInProgress = false
    private let access: PasteboardAccessing

    init(access: PasteboardAccessing = SystemPasteboardAccess()) {
        self.access = access
    }

    func capture(timeout: TimeInterval) async -> PasteboardCaptureResult {
        await withCheckedContinuation { continuation in
            guard beginCapture() else {
                continuation.resume(returning: .busy)
                return
            }

            let resolution = OneShotResolution<PasteboardCaptureResult> { result in
                continuation.resume(returning: result)
            }

            workerQueue.async { [self] in
                defer { endCapture() }
                resolution.resolve(access.capture())
            }

            timeoutQueue.asyncAfter(deadline: .now() + timeout) {
                resolution.resolve(.timedOut)
            }
        }
    }

    func write(text: String, replacing snapshot: PasteboardSnapshot) async -> PasteboardWriteResult {
        await withCheckedContinuation { continuation in
            workerQueue.async { [self] in
                continuation.resume(returning: access.write(text: text, replacing: snapshot))
            }
        }
    }

    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) async -> PasteboardRestoreResult {
        await withCheckedContinuation { continuation in
            workerQueue.async { [self] in
                continuation.resume(returning: access.restore(snapshot, expectedChangeCount: expectedChangeCount))
            }
        }
    }

    private func beginCapture() -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard !captureInProgress else { return false }
        captureInProgress = true
        return true
    }

    private func endCapture() {
        captureLock.lock()
        captureInProgress = false
        captureLock.unlock()
    }
}

final class SystemPasteboardAccess: PasteboardAccessing {
    func capture() -> PasteboardCaptureResult {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        var allItems: [[PasteboardSnapshot.Entry]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [PasteboardSnapshot.Entry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append(.init(type: type, data: data))
                }
            }
            allItems.append(itemData)
        }

        guard pasteboard.changeCount == initialChangeCount else { return .changed }
        return .captured(.init(items: allItems, changeCount: initialChangeCount))
    }

    func write(text: String, replacing snapshot: PasteboardSnapshot) -> PasteboardWriteResult {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == snapshot.changeCount else { return .changed }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            _ = restore(snapshot, expectedChangeCount: pasteboard.changeCount)
            return .failed
        }
        return .written(changeCount: pasteboard.changeCount)
    }

    func restore(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) -> PasteboardRestoreResult {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else { return .skippedChanged }

        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return .restored }

        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        return pasteboard.writeObjects(items) ? .restored : .failed
    }
}

private final class OneShotResolution<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    init(callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func resolve(_ value: Value) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(value)
    }
}
