import Foundation
@testable import AtomVoiceCore

enum TextInjectionLifecycleTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Text injection timeout cancels work before clipboard commit") {
            var lifecycle = TextInjectionLifecycle()
            let id = UUID()
            lifecycle.start(id: id)

            try expect(lifecycle.handleTimeout(id: id) == .cancel)
            try expect(!lifecycle.isActive)
            try expect(!lifecycle.finish(id: id))
        }

        await runner.run("Text injection snapshot timeout rejects late continuation") {
            var lifecycle = TextInjectionLifecycle()
            let expiredID = UUID()
            lifecycle.start(id: expiredID)
            try expect(lifecycle.transition(id: expiredID, from: .preparing, to: .snapshotting))
            try expect(lifecycle.handleTimeout(id: expiredID) == .cancel)

            let currentID = UUID()
            lifecycle.start(id: currentID)
            try expect(!lifecycle.transition(id: expiredID, from: .snapshotting, to: .committing))
            try expect(lifecycle.isCurrent(currentID))
        }

        await runner.run("Text injection timeout waits after clipboard commit") {
            var lifecycle = TextInjectionLifecycle()
            let id = UUID()
            lifecycle.start(id: id)
            try expect(lifecycle.transition(id: id, from: .preparing, to: .snapshotting))
            try expect(lifecycle.transition(id: id, from: .snapshotting, to: .committing))

            try expect(lifecycle.handleTimeout(id: id) == .waitForCleanup)
            try expect(lifecycle.isCurrent(id))
            try expect(lifecycle.finish(id: id))
        }

        await runner.run("Text injection completion can win only once") {
            var lifecycle = TextInjectionLifecycle()
            let id = UUID()
            lifecycle.start(id: id)

            try expect(lifecycle.finish(id: id))
            try expect(!lifecycle.finish(id: id))
            try expect(lifecycle.handleTimeout(id: id) == .stale)
        }
    }
}
