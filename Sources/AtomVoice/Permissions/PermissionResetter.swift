import Foundation

protocol PermissionResetting: AnyObject {
    func resetPermissions(doneMessage: String)
}

/// 仅迁移既有 Terminal/tccutil 动作；窗口仍负责原有确认流程。
final class SystemPermissionResetter: PermissionResetting {
    func resetPermissions(doneMessage: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "--args", "-e",
            "tccutil reset Microphone com.blacksquarre.AtomVoice && " +
            "tccutil reset SpeechRecognition com.blacksquarre.AtomVoice && " +
            "printf '%s\\n' \(Self.shellQuoted(doneMessage))"]
        try? task.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
