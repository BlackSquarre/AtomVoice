import Cocoa
import Darwin
import Foundation

protocol SingleInstanceRunningApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var executableURL: URL? { get }

    @discardableResult
    func terminate() -> Bool
    @discardableResult
    func forceTerminate() -> Bool
}

extension NSRunningApplication: SingleInstanceRunningApplication {}

protocol SingleInstanceEnvironment {
    func pidFileURL(bundleIdentifier: String?) -> URL?
    func readPIDFile(at url: URL) -> Int32?
    func writePIDFile(_ pid: Int32, at url: URL)
    func removePIDFile(at url: URL)
    func processIsAlive(pid: Int32) -> Bool
    func runningApplication(forPID pid: Int32) -> (any SingleInstanceRunningApplication)?
    func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [any SingleInstanceRunningApplication]
    func sameExecutableRunningApplications(matching url: URL) -> [any SingleInstanceRunningApplication]
}

struct DefaultSingleInstanceEnvironment: SingleInstanceEnvironment {
    func pidFileURL(bundleIdentifier: String?) -> URL? {
        guard let bundleIdentifier else { return nil }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.error("[AppDelegate] Failed to create single-instance PID directory: \(error.localizedDescription)")
            return nil
        }
        return directory.appendingPathComponent("AtomVoice.pid")
    }

    func readPIDFile(at url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw) else {
            return nil
        }
        return pid
    }

    func writePIDFile(_ pid: Int32, at url: URL) {
        do {
            try String(pid).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DebugLog.error("[AppDelegate] Failed to write single-instance PID file: \(error.localizedDescription)")
        }
    }

    func removePIDFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func processIsAlive(pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    func runningApplication(forPID pid: Int32) -> (any SingleInstanceRunningApplication)? {
        NSRunningApplication(processIdentifier: pid)
    }

    func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [any SingleInstanceRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    func sameExecutableRunningApplications(matching url: URL) -> [any SingleInstanceRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.standardizedFileURL == url
        }
    }
}

final class SingleInstanceController {
    private let environment: SingleInstanceEnvironment
    private let bundleIdentifierProvider: () -> String?

    init(
        environment: SingleInstanceEnvironment = DefaultSingleInstanceEnvironment(),
        bundleIdentifierProvider: @escaping () -> String? = { Bundle.main.bundleIdentifier }
    ) {
        self.environment = environment
        self.bundleIdentifierProvider = bundleIdentifierProvider
    }

    /// 启动时调用：清理同 bundle id 的旧实例 + 写当前 PID 文件。
    func claimSingleInstance(currentPID: Int32, bundleIdentifier: String?, currentExecutableURL: URL?) {
        guard let bundleIdentifier else { return }

        terminatePIDFromPreviousLaunchIfNeeded(currentPID: currentPID, bundleIdentifier: bundleIdentifier)

        var candidates: [Int32: any SingleInstanceRunningApplication] = [:]
        environment.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }
            .forEach { candidates[$0.processIdentifier] = $0 }

        if let currentExecutableURL {
            environment.sameExecutableRunningApplications(matching: currentExecutableURL)
                .filter { $0.processIdentifier != currentPID }
                .forEach { candidates[$0.processIdentifier] = $0 }
        }

        writeSingleInstancePIDFile(currentPID, bundleIdentifier: bundleIdentifier)

        let otherApps = Array(candidates.values)
        guard !otherApps.isEmpty else { return }

        // 菜单栏应用不应该多开；新实例启动时清理旧实例，避免多个事件 tap 同时抢耳机线控。
        otherApps.forEach { app in
            DebugLog.info("[AppDelegate] Terminating older instance pid=\(app.processIdentifier)")
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            otherApps.filter { !$0.isTerminated }.forEach { app in
                DebugLog.info("[AppDelegate] Older instance did not terminate cleanly, force terminating pid=\(app.processIdentifier)")
                app.forceTerminate()
            }
        }
    }

    /// applicationWillTerminate 调用：仅当 PID 文件指向自己时删除。
    func releaseSingleInstance(currentPID: Int32) {
        guard let bundleIdentifier = bundleIdentifierProvider() else { return }
        guard let url = environment.pidFileURL(bundleIdentifier: bundleIdentifier) else { return }
        guard environment.readPIDFile(at: url) == currentPID else { return }
        environment.removePIDFile(at: url)
    }

    private func terminatePIDFromPreviousLaunchIfNeeded(currentPID: Int32, bundleIdentifier: String) {
        guard let pid = readSingleInstancePIDFile(bundleIdentifier: bundleIdentifier), pid != currentPID else { return }
        guard environment.processIsAlive(pid: pid) else { return }
        guard let app = environment.runningApplication(forPID: pid) else { return }

        DebugLog.info("[AppDelegate] PID file points to older instance pid=\(pid)")
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !app.isTerminated {
                DebugLog.info("[AppDelegate] PID-file instance did not terminate cleanly, force terminating pid=\(pid)")
                app.forceTerminate()
            }
        }
    }

    private func readSingleInstancePIDFile(bundleIdentifier: String) -> Int32? {
        guard let url = environment.pidFileURL(bundleIdentifier: bundleIdentifier) else { return nil }
        return environment.readPIDFile(at: url)
    }

    private func writeSingleInstancePIDFile(_ pid: Int32, bundleIdentifier: String) {
        guard let url = environment.pidFileURL(bundleIdentifier: bundleIdentifier) else { return }
        environment.writePIDFile(pid, at: url)
    }
}
