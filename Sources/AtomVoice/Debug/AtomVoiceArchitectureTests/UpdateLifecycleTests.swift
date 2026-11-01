import Foundation
@testable import AtomVoiceCore

enum UpdateLifecycleTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Update archive is owned before borrowed download file disappears") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let borrowed = directory.appendingPathComponent("borrowed.zip")
            let bytes = Data("archive fixture".utf8)
            try bytes.write(to: borrowed)
            var artifact: OwnedUpdateArtifact? = try .acquireDownload(borrowed)
            let ownedURL = artifact!.url
            let ownedDirectory = artifact!.directoryURL
            try FileManager.default.removeItem(at: borrowed)
            let persistedBytes = try Data(contentsOf: ownedURL)
            try expect(persistedBytes == bytes)
            artifact = nil
            try expect(!FileManager.default.fileExists(atPath: ownedDirectory.path))
        }

        await runner.run("Update Later retains application and manual check prompts without downloading again") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            let checker = makeChecker(source, installer, presenter)
            checker.checkForUpdates()
            try await waitUntil { checker.state == .readyToRestart }
            try expect(presenter.restartPrompts == 1 && presenter.terminations == 0)
            let app = try require(installer.applicationURL)
            try expect(FileManager.default.fileExists(atPath: app.path))
            checker.resumeDeferredRestartPromptIfPossible()
            try expect(presenter.restartPrompts == 1)
            checker.checkForUpdates(silent: true)
            try expect(presenter.restartPrompts == 1)
            checker.checkForUpdates()
            try await waitUntil { presenter.restartPrompts == 2 }
            try expect(source.downloads == 1 && source.fetches == 2)
            try expect(installer.archiveWasReadable)
        }

        await runner.run("Update Later does not prevent checking a newer release and declined replacement keeps old app") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            let checker = makeChecker(source, installer, presenter)
            checker.checkForUpdates()
            try await waitUntil { checker.state == .readyToRestart }
            let oldApp = try require(installer.applicationURL)
            source.release = ReleaseInfo(version: "3.0.0", downloadURL: URL(string: "https://fixture.invalid/new-archive")!,
                assetName: "new.zip", checksumsURL: source.release.checksumsURL, isPreRelease: false, isDebugBuild: false)
            presenter.downloadNow = false
            checker.checkForUpdates()
            try await waitUntil { presenter.downloadPrompts == 2 }
            try expect(checker.state == .readyToRestart && source.fetches == 2)
            try expect(source.downloads == 1 && FileManager.default.fileExists(atPath: oldApp.path))
            presenter.downloadNow = true
            checker.checkForUpdates()
            try await waitUntil { presenter.restartPrompts == 2 }
            try expect(source.downloads == 2)
            try expect(!FileManager.default.fileExists(atPath: oldApp.path))
            try expect(installer.applicationURL != oldApp)
        }

        await runner.run("Update restart modal cannot reenter a second check or restart prompt") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            let checker = makeChecker(source, installer, presenter)
            presenter.onRestartPrompt = { [weak checker] in
                checker?.checkForUpdates()
                checker?.resumeDeferredRestartPromptIfPossible()
            }
            checker.checkForUpdates()
            try await waitUntil { checker.state == .readyToRestart }
            try expect(presenter.restartPrompts == 1 && source.fetches == 1)
        }

        await runner.run("Update recording deferral resumes once and Later stays quiet") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            let checker = makeChecker(source, installer, presenter)
            var busy = true
            checker.shouldDeferRestartPrompt = { busy }
            checker.checkForUpdates()
            try await waitUntil { checker.state == .readyToRestart }
            try expect(presenter.restartPrompts == 0)
            busy = false
            checker.resumeDeferredRestartPromptIfPossible()
            checker.resumeDeferredRestartPromptIfPossible()
            try expect(presenter.restartPrompts == 1)
            try expect(installer.applicationURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        }

        for stage in [LifecycleInstaller.Failure.checksum, .extract, .validation] {
            await runner.run("Update failed \(stage) releases archive and staged application") {
                let source = LifecycleReleaseSource()
                let installer = LifecycleInstaller()
                installer.failure = stage
                defer { installer.removeFixtures() }
                let presenter = LifecyclePresenter()
                let checker = makeChecker(source, installer, presenter)
                checker.checkForUpdates()
                try await waitUntil { !presenter.alerts.isEmpty }
                try expect(checker.state == .idle)
                try expect(presenter.progressCloses == 1 && presenter.restartPrompts == 0)
                try await waitUntil { installer.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
                if let archive = source.archiveDirectory {
                    try await waitUntil { !FileManager.default.fileExists(atPath: archive.path) }
                }
            }
        }

        await runner.run("Update checksum listing failure releases acquired archive") {
            let source = LifecycleReleaseSource()
            source.listingFails = true
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            let checker = makeChecker(source, installer, presenter)
            checker.checkForUpdates()
            try await waitUntil { !presenter.alerts.isEmpty }
            try expect(checker.state == .idle && installer.directories.isEmpty)
            let archive = try require(source.archiveDirectory)
            try await waitUntil { !FileManager.default.fileExists(atPath: archive.path) }
        }

        await runner.run("Update failed process handoff retains app and retries only on manual request") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            installer.failure = .apply
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            presenter.restartNow = true
            let checker = makeChecker(source, installer, presenter)
            checker.checkForUpdates()
            try await waitUntil { !presenter.alerts.isEmpty }
            let app = try require(installer.applicationURL)
            try expect(checker.state == .readyToRestart)
            try expect(presenter.terminations == 0 && installer.applies == 1)
            try expect(FileManager.default.fileExists(atPath: app.path))
            checker.resumeDeferredRestartPromptIfPossible()
            try expect(installer.applies == 1)
            installer.failure = nil
            checker.checkForUpdates()
            try await waitUntil { presenter.terminations == 1 }
            try expect(checker.state == .applying && installer.applies == 2 && presenter.terminations == 1)
            try expect(FileManager.default.fileExists(atPath: app.path))
        }

        await runner.run("Update abandoned prompt performs no download and leaves idle") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            let presenter = LifecyclePresenter()
            presenter.downloadNow = false
            let checker = makeChecker(source, installer, presenter)
            checker.checkForUpdates()
            try await waitUntil { presenter.downloadPrompts == 1 }
            try expect(checker.state == .idle && source.downloads == 0 && installer.directories.isEmpty)
        }

        await runner.run("Update pending owned app is released with its coordinator") {
            let source = LifecycleReleaseSource()
            let installer = LifecycleInstaller()
            defer { installer.removeFixtures() }
            let presenter = LifecyclePresenter()
            var checker: UpdateChecker? = makeChecker(source, installer, presenter)
            checker?.checkForUpdates()
            try await waitUntil { checker?.state == .readyToRestart }
            let app = try require(installer.applicationURL)
            checker = nil
            try expect(!FileManager.default.fileExists(atPath: app.path))
        }

        await runner.run("Installer script copy failure restores fixture bundle and cleans handed-off staging") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let current = directory.appendingPathComponent("current.app")
            let stage = directory.appendingPathComponent("stage")
            let newApp = stage.appendingPathComponent("new.app")
            let tools = directory.appendingPathComponent("tools")
            for folder in [current, newApp, tools] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("original fixture".utf8).write(to: current.appendingPathComponent("marker"))
            try Data("new fixture".utf8).write(to: newApp.appendingPathComponent("marker"))
            for (name, code) in [("ditto", 1), ("open", 0), ("sleep", 0)] {
                let tool = tools.appendingPathComponent(name)
                try "#!/bin/bash\nexit \(code)\n".write(to: tool, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            }
            let script = directory.appendingPathComponent("install.sh")
            try BundleUpdateInstaller.installationScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, current.path, newApp.path, stage.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(tools.path):/usr/bin:/bin"
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            let restored = try Data(contentsOf: current.appendingPathComponent("marker"))
            try expect(process.terminationStatus == 1)
            try expect(restored == Data("original fixture".utf8))
            try expect(!FileManager.default.fileExists(atPath: stage.path))
            try expect(!FileManager.default.fileExists(atPath: current.path + ".previous"))
            try expect(!FileManager.default.fileExists(atPath: script.path))
        }

        await runner.run("Production unzip failure removes its newly created stage directory") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = directory.appendingPathComponent("invalid.zip")
            try Data("invalid archive fixture".utf8).write(to: archive)
            let temporary = FileManager.default.temporaryDirectory
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("AtomVoiceUpdate-") })
            let installer = BundleUpdateInstaller(expectedBundleIdentifier: "fixture", expectedTeamIdentifier: "fixture", isNewer: { _, _ in true })
            do {
                _ = try installer.extractZip(archive)
                throw TestFailure(file: #filePath, line: #line, message: "Expected invalid fixture archive to fail")
            } catch is UpdateInstallError {}
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("AtomVoiceUpdate-") })
            try expect(before == after)
        }
    }

    private static func makeChecker(_ source: LifecycleReleaseSource, _ installer: LifecycleInstaller,
                                    _ presenter: LifecyclePresenter) -> UpdateChecker {
        UpdateChecker(releaseSource: source, installer: installer, presenter: presenter,
                      currentVersion: { "1.0.0" }, currentBundlePath: { "/fixture/AtomVoice.app" })
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try expect(predicate(), "Timed out waiting for offline update fixture")
    }

    fileprivate static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoiceUpdateFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LifecycleReleaseSource: ReleaseSource {
    var release = ReleaseInfo(version: "2.0.0", downloadURL: URL(string: "https://fixture.invalid/archive")!,
        assetName: "fixture.zip", checksumsURL: URL(string: "https://fixture.invalid/checksums")!, isPreRelease: false, isDebugBuild: false)
    var downloads = 0
    var fetches = 0
    var listingFails = false
    var archiveDirectory: URL?
    func fetchLatestRelease(includeBeta: Bool, preferDebugBuild: Bool, completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        fetches += 1
        completion(.success(release))
    }
    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<OwnedUpdateArtifact, Error>) -> Void) {
        downloads += 1
        do {
            let directory = try UpdateLifecycleTests.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let borrowed = directory.appendingPathComponent("borrowed.zip")
            try Data("archive fixture".utf8).write(to: borrowed)
            let archive = try OwnedUpdateArtifact.acquireDownload(borrowed)
            archiveDirectory = archive.directoryURL
            completion(.success(archive))
            // 模拟 URLSession 在回调返回后立刻删除借用的下载 URL。
        } catch { completion(.failure(error)) }
    }
    func fetchChecksumsListing(for release: ReleaseInfo, completion: @escaping (Result<String, Error>) -> Void) {
        completion(listingFails ? .failure(URLError(.cannotLoadFromNetwork)) : .success("fixture listing"))
    }
}

private final class LifecycleInstaller: UpdateInstaller {
    enum Failure: Error { case checksum, extract, validation, apply }
    var failure: Failure?
    var archiveWasReadable = false
    var directories: [URL] = []
    var applicationURL: URL?
    var applies = 0
    func verifyChecksum(zipURL: URL, listing: String, assetName: String) throws {
        archiveWasReadable = try Data(contentsOf: zipURL) == Data("archive fixture".utf8)
        if failure == .checksum { throw Failure.checksum }
    }
    func extractZip(_ zipURL: URL) throws -> OwnedUpdateArtifact {
        let directory = try UpdateLifecycleTests.temporaryDirectory()
        directories.append(directory)
        let app = directory.appendingPathComponent("AtomVoice.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let artifact = OwnedUpdateArtifact(url: app, directoryURL: directory)
        if failure == .extract { throw Failure.extract }
        applicationURL = app
        return artifact
    }
    func validateDownloadedApp(_ appURL: URL, currentVersion: String, expectedVersion: String) throws {
        if failure == .validation { throw Failure.validation }
    }
    func applyAndRelaunch(newAppURL: URL, currentBundlePath: String) throws {
        applies += 1
        if failure == .apply { throw Failure.apply }
    }
    func removeFixtures() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

private final class LifecyclePresenter: UpdatePresenting {
    var downloadNow = true
    var restartNow = false
    var downloadPrompts = 0
    var restartPrompts = 0
    var progressCloses = 0
    var terminations = 0
    var alerts: [String] = []
    var onRestartPrompt: (() -> Void)?
    func confirmDownload(version: String, currentVersion: String, isPreRelease: Bool, isDebugBuild: Bool) -> Bool {
        downloadPrompts += 1
        return downloadNow
    }
    func confirmRestart(version: String) -> Bool {
        restartPrompts += 1
        onRestartPrompt?()
        return restartNow
    }
    func showProgress(_ message: String) {}
    func updateProgressLabel(_ message: String) {}
    func closeProgress() { progressCloses += 1 }
    func bringProgressToFront() {}
    func showAlert(title: String, message: String) { alerts.append(message) }
    func terminateApplication() { terminations += 1 }
}
