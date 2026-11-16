#if DEBUG_BUILD
import Foundation

struct DebugOOBESnapshotArguments {
    let step: Int

    static var current: DebugOOBESnapshotArguments? {
        if let step = Bundle.main.object(forInfoDictionaryKey: "AtomVoiceOOBESnapshotStep") as? Int {
            return DebugOOBESnapshotArguments(step: step)
        }
        var args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--debug-oobe-snapshot-step") else { return nil }
        guard args.indices.contains(index + 1), let step = Int(args[index + 1]) else { return nil }
        args.removeSubrange(index...index + 1)
        return DebugOOBESnapshotArguments(step: step)
    }
}

struct DebugASRSettingsSnapshotArguments {
    let tabIdentifier: String

    static var current: DebugASRSettingsSnapshotArguments? {
        if let tab = Bundle.main.object(forInfoDictionaryKey: "AtomVoiceASRSnapshotTab") as? String {
            return DebugASRSettingsSnapshotArguments(tabIdentifier: tab)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        if let index = args.firstIndex(of: "--debug-asr-settings-snapshot-tab"),
           args.indices.contains(index + 1) {
            return DebugASRSettingsSnapshotArguments(tabIdentifier: args[index + 1])
        }
        if args.contains("--debug-asr-settings-snapshot") {
            return DebugASRSettingsSnapshotArguments(tabIdentifier: "doubao")
        }
        return nil
    }
}
struct DebugPreferencesSnapshotArguments {
    let page: String
    static var current: Self? {
        if let page = Bundle.main.object(forInfoDictionaryKey: "AtomVoicePreferencesSnapshotPage") as? String { return Self(page: page) }
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--debug-preferences-snapshot"), args.indices.contains(index + 1) else { return nil }
        return Self(page: args[index + 1])
    }
}
#endif
