import Foundation

enum TextInjectionPhase: Equatable {
    case preparing
    case snapshotting
    case committing
    case restoring
}

enum TextInjectionTimeoutDecision: Equatable {
    case cancel
    case waitForCleanup
    case stale
}

struct TextInjectionLifecycle {
    private(set) var activeID: UUID?
    private(set) var phase: TextInjectionPhase?

    var isActive: Bool { activeID != nil }

    mutating func start(id: UUID) {
        precondition(activeID == nil)
        activeID = id
        phase = .preparing
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func transition(
        id: UUID,
        from expectedPhase: TextInjectionPhase,
        to newPhase: TextInjectionPhase
    ) -> Bool {
        guard activeID == id, phase == expectedPhase else { return false }
        phase = newPhase
        return true
    }

    mutating func finish(id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        phase = nil
        return true
    }

    mutating func handleTimeout(id: UUID) -> TextInjectionTimeoutDecision {
        guard activeID == id, let phase else { return .stale }
        switch phase {
        case .preparing, .snapshotting:
            activeID = nil
            self.phase = nil
            return .cancel
        case .committing, .restoring:
            return .waitForCleanup
        }
    }
}
