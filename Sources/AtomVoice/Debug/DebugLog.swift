import Foundation
import os.log

/// 调试日志系统（Debug logger）
///
/// Debug 构建时将日志写入文件，Release 构建时静默。
/// 日志文件位于 ~/Library/Logs/AtomVoice/debug.log
enum DebugLog {
    private static let subsystem = "com.blacksquarre.AtomVoice"
    private static let logger = Logger(subsystem: subsystem, category: "debug")

    private static var logFileHandle: FileHandle? = {
        let fm = FileManager.default
        let logsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AtomVoice")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fileURL = logsDir.appendingPathComponent("debug.log")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: fileURL)
    }()

    private static let queue = DispatchQueue(label: "com.atomvoice.debugLog", qos: .utility)

    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG_BUILD
        write(level: "INFO", message())
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG_BUILD
        write(level: "ERROR", message())
        #endif
    }

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG_BUILD
        write(level: "DEBUG", message())
        #endif
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func write(level: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"

        logger.info("\(line, privacy: .public)")

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            logFileHandle?.seekToEndOfFile()
            logFileHandle?.write(data)
        }
    }
}
