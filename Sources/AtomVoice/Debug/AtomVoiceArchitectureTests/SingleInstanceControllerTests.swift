import Cocoa
import Foundation
@testable import AtomVoiceCore

enum SingleInstanceControllerTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("claimSingleInstance writes PID file when bundle id and url provided") {
            let executableURL = URL(fileURLWithPath: "/Applications/AtomVoice.app/Contents/MacOS/AtomVoice").standardizedFileURL
            let environment = FakeSingleInstanceEnvironment()
            let controller = SingleInstanceController(environment: environment)

            controller.claimSingleInstance(
                currentPID: 42,
                bundleIdentifier: "com.blacksquarre.AtomVoice",
                currentExecutableURL: executableURL
            )

            try expect(environment.writtenPID == 42)
            try expect(environment.requestedBundleIdentifiers == ["com.blacksquarre.AtomVoice"])
            try expect(environment.sameExecutableQueryURLs == [executableURL])
        }

        await runner.run("claimSingleInstance terminates older instances from previous launch") {
            let environment = FakeSingleInstanceEnvironment()
            let previous = FakeSingleInstanceApplication(pid: 41)
            environment.pidFileValue = 41
            environment.processesAlive.insert(41)
            environment.applicationByPID[41] = previous
            let controller = SingleInstanceController(environment: environment)

            controller.claimSingleInstance(
                currentPID: 42,
                bundleIdentifier: "com.blacksquarre.AtomVoice",
                currentExecutableURL: nil
            )

            try expect(previous.terminateCount == 1)
            try expect(environment.writtenPID == 42)
        }

        await runner.run("claimSingleInstance is no-op when bundleIdentifier nil") {
            let environment = FakeSingleInstanceEnvironment()
            let controller = SingleInstanceController(environment: environment)

            controller.claimSingleInstance(
                currentPID: 42,
                bundleIdentifier: nil,
                currentExecutableURL: URL(fileURLWithPath: "/tmp/AtomVoice")
            )

            try expect(environment.writtenPID == nil)
            try expect(environment.pidFileRequestCount == 0)
            try expect(environment.requestedBundleIdentifiers.isEmpty)
        }

        await runner.run("releaseSingleInstance removes PID file only when it points to self") {
            let environment = FakeSingleInstanceEnvironment()
            environment.pidFileValue = 42
            let controller = SingleInstanceController(
                environment: environment,
                bundleIdentifierProvider: { "com.blacksquarre.AtomVoice" }
            )

            controller.releaseSingleInstance(currentPID: 42)

            try expect(environment.removedPIDFile)
        }

        await runner.run("releaseSingleInstance is no-op when PID file points to another process") {
            let environment = FakeSingleInstanceEnvironment()
            environment.pidFileValue = 41
            let controller = SingleInstanceController(
                environment: environment,
                bundleIdentifierProvider: { "com.blacksquarre.AtomVoice" }
            )

            controller.releaseSingleInstance(currentPID: 42)

            try expect(!environment.removedPIDFile)
        }
    }
}

private final class FakeSingleInstanceEnvironment: SingleInstanceEnvironment {
    let pidFileURL = URL(fileURLWithPath: "/tmp/AtomVoice.pid")
    var pidFileValue: Int32?
    var writtenPID: Int32?
    var removedPIDFile = false
    var pidFileRequestCount = 0
    var requestedBundleIdentifiers: [String] = []
    var sameExecutableQueryURLs: [URL] = []
    var processesAlive: Set<Int32> = []
    var applicationByPID: [Int32: FakeSingleInstanceApplication] = [:]
    var bundleApplications: [FakeSingleInstanceApplication] = []
    var sameExecutableApplications: [FakeSingleInstanceApplication] = []

    func pidFileURL(bundleIdentifier: String?) -> URL? {
        pidFileRequestCount += 1
        guard bundleIdentifier != nil else { return nil }
        return pidFileURL
    }

    func readPIDFile(at url: URL) -> Int32? {
        pidFileValue
    }

    func writePIDFile(_ pid: Int32, at url: URL) {
        writtenPID = pid
        pidFileValue = pid
    }

    func removePIDFile(at url: URL) {
        removedPIDFile = true
        pidFileValue = nil
    }

    func processIsAlive(pid: Int32) -> Bool {
        processesAlive.contains(pid)
    }

    func runningApplication(forPID pid: Int32) -> (any SingleInstanceRunningApplication)? {
        applicationByPID[pid]
    }

    func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [any SingleInstanceRunningApplication] {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return bundleApplications
    }

    func sameExecutableRunningApplications(matching url: URL) -> [any SingleInstanceRunningApplication] {
        sameExecutableQueryURLs.append(url)
        return sameExecutableApplications
    }
}

private final class FakeSingleInstanceApplication: SingleInstanceRunningApplication {
    let processIdentifier: pid_t
    var isTerminated = false
    var executableURL: URL?
    var terminateCount = 0
    var forceTerminateCount = 0

    init(pid: pid_t, executableURL: URL? = nil) {
        self.processIdentifier = pid
        self.executableURL = executableURL
    }

    func terminate() -> Bool {
        terminateCount += 1
        isTerminated = true
        return true
    }

    func forceTerminate() -> Bool {
        forceTerminateCount += 1
        isTerminated = true
        return true
    }
}
