import Foundation

final class RecordingStateBroadcaster {
    typealias RecordingHandler = (Bool) -> Void
    typealias RefiningHandler = (Bool) -> Void

    private var recordingObservers: [RecordingHandler] = []
    private var refiningObservers: [RefiningHandler] = []

    /// 按注册顺序广播。注册者负责自己持有的弱引用。
    func addRecordingObserver(_ handler: @escaping RecordingHandler) {
        recordingObservers.append(handler)
    }

    /// 按注册顺序广播。注册者负责自己持有的弱引用。
    func addRefiningObserver(_ handler: @escaping RefiningHandler) {
        refiningObservers.append(handler)
    }

    func broadcastRecordingStateChanged(_ active: Bool) {
        recordingObservers.forEach { $0(active) }
    }

    func broadcastRefiningStateChanged(_ refining: Bool) {
        refiningObservers.forEach { $0(refining) }
    }
}
