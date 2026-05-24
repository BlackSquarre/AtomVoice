#if DEBUG_BUILD
import Foundation

struct DebugOOBESnapshotArguments {
    let step: Int

    static var current: DebugOOBESnapshotArguments? {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--debug-oobe-snapshot-step") else { return nil }
        guard args.indices.contains(index + 1), let step = Int(args[index + 1]) else { return nil }
        args.removeSubrange(index...index + 1)
        return DebugOOBESnapshotArguments(step: step)
    }
}
#endif
