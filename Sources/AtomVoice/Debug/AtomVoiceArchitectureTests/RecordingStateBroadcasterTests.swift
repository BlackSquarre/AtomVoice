import Foundation
@testable import AtomVoiceCore

enum RecordingStateBroadcasterTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("addRecordingObserver invokes handler with each broadcast in registration order") {
            let broadcaster = RecordingStateBroadcaster()
            var events: [String] = []
            broadcaster.addRecordingObserver { events.append("first:\($0)") }
            broadcaster.addRecordingObserver { events.append("second:\($0)") }

            broadcaster.broadcastRecordingStateChanged(true)
            broadcaster.broadcastRecordingStateChanged(false)

            try expect(events == ["first:true", "second:true", "first:false", "second:false"])
        }

        await runner.run("addRefiningObserver invokes handler with each broadcast in registration order") {
            let broadcaster = RecordingStateBroadcaster()
            var events: [String] = []
            broadcaster.addRefiningObserver { events.append("first:\($0)") }
            broadcaster.addRefiningObserver { events.append("second:\($0)") }

            broadcaster.broadcastRefiningStateChanged(true)
            broadcaster.broadcastRefiningStateChanged(false)

            try expect(events == ["first:true", "second:true", "first:false", "second:false"])
        }

        await runner.run("broadcastRecordingStateChanged with no observers is no-op") {
            let broadcaster = RecordingStateBroadcaster()

            broadcaster.broadcastRecordingStateChanged(true)
            broadcaster.broadcastRecordingStateChanged(false)

            try expect(true)
        }

        await runner.run("broadcasting from one observer does not interfere with another observer's state") {
            let broadcaster = RecordingStateBroadcaster()
            var firstState = false
            var secondState = false
            broadcaster.addRecordingObserver { active in
                firstState = active
            }
            broadcaster.addRecordingObserver { active in
                secondState = !active
            }

            broadcaster.broadcastRecordingStateChanged(true)

            try expect(firstState)
            try expect(!secondState)
        }
    }
}
