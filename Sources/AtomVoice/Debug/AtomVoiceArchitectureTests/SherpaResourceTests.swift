import Foundation
@testable import AtomVoiceCore

enum SherpaResourceTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Sherpa resource inspection discovers model without writing manifest cache") {
            try withFixture { paths, preset in
                try model(at: paths.model(preset))
                let status = SherpaResources(paths: paths).status(for: preset)
                try expect(status.modelReady && !status.runtimeReady && !status.punctuationReady)
                try expect(!FileManager.default.fileExists(atPath: paths.model(preset).appendingPathComponent(ModelManifest.filename).path))
            }
        }
        await runner.run("Sherpa optional punctuation absence preserves recognition readiness and manifest recovery") {
            try withFixture { paths, preset in
                try model(at: paths.model(preset))
                try readyRuntime(paths)
                let resources = SherpaResources(paths: paths)
                try expect(resources.status(for: preset).recognitionReady)
                try expect(!resources.status(for: preset).allReady)
                try expect(resources.ensureRecognitionReady(for: preset))
                try expect(ModelManifest.load(from: paths.model(preset)) != nil)
            }
        }
        await runner.run("Sherpa plan distinguishes supplement model replacement and runtime update") {
            try withFixture { paths, preset in
                try model(at: paths.model(preset))
                try readyRuntime(paths)
                try write("punct", at: paths.punctuation.appendingPathComponent("model.int8.onnx"))
                let installer = SherpaDownloadInstallation(paths: paths)
                try expect(installer.plan(preset: preset, version: "fixture", forceRuntime: false, runtimeOnly: false, replaceModel: false).isEmpty)
                try expect(installer.plan(preset: preset, version: "fixture", forceRuntime: false, runtimeOnly: false, replaceModel: true).map(\.kind) == [.asr])
                try expect(installer.plan(preset: preset, version: "fixture", forceRuntime: true, runtimeOnly: true, replaceModel: true).map(\.kind) == [.runtime])
            }
        }
        await runner.run("Sherpa repair supplements missing library from recorded version without replacing usable target") {
            try withFixture { paths, _ in
                let existing = SherpaResourcePaths.runtimeLibraries[0]
                let missing = SherpaResourcePaths.runtimeLibraries[1]
                try write("keep", at: paths.runtime.appendingPathComponent(existing))
                try write("v-new", at: paths.version)
                for version in ["v-old", "v-new"] {
                    let source = paths.support.appendingPathComponent(SherpaModelDownloader.runtimeArchiveRootName(for: version))
                    for name in SherpaResourcePaths.runtimeLibraries { try write(version, at: source.appendingPathComponent("lib/" + name)) }
                }
                try SherpaResources(paths: paths).repairRuntimeIfNeeded()
                try expect((try? String(contentsOf: paths.runtime.appendingPathComponent(existing))) == "keep")
                try expect((try? String(contentsOf: paths.runtime.appendingPathComponent(missing))) == "v-new")
            }
        }
        await runner.run("Sherpa same-directory replacement never deletes source") {
            try withFixture { paths, preset in
                let directory = paths.model(preset)
                try model(at: directory)
                let installed = try SherpaResourceInstaller.replaceDirectory(from: directory, to: directory)
                installed.rollback()
                try expect(ModelManifest.inspect(in: directory) != nil)
            }
        }
        await runner.run("Sherpa directory replacement rolls back old data until committed") {
            try withFixture { paths, preset in
                let target = paths.model(preset)
                let source = paths.support.appendingPathComponent("source")
                try write("old", at: target.appendingPathComponent("value"))
                try write("new", at: source.appendingPathComponent("value"))
                let installed = try SherpaResourceInstaller.replaceDirectory(from: source, to: target)
                try expect((try? String(contentsOf: target.appendingPathComponent("value"))) == "new")
                installed.rollback()
                try expect((try? String(contentsOf: target.appendingPathComponent("value"))) == "old")
                try expect((try? String(contentsOf: source.appendingPathComponent("value"))) == "new")
            }
        }
        await runner.run("Sherpa import from installed source survives cancellation and failed record persistence") {
            try withFixture { paths, preset in
                let source = paths.model(preset)
                try model(at: source)
                let installer = SherpaModelImportInstaller(paths: paths)
                do {
                    let prepared = try installer.prepare(source).get()
                    try expect(prepared.targetName == source.lastPathComponent)
                }
                try expect(ModelManifest.inspect(in: source) != nil)
                let prepared = try installer.prepare(source).get()
                let backend = RejectingSherpaBackend()
                let store = SherpaImportedPresetStore(backend: backend)
                let record = SherpaImportedPresetRecord(id: "fixture", language: "en-US", extractedDirName: preset.extractedDirName, sizeMB: 0, importedAt: Date())
                switch installer.install(prepared, record: record, store: store) {
                case .success: throw TestFailure(file: #filePath, line: #line, message: "Rejected store must fail import")
                case .failure: break
                }
                try expect(store.records.isEmpty)
                try expect(ModelManifest.inspect(in: source) != nil)
            }
        }
        await runner.run("Sherpa deleting active imported model persists fallback and precise selection notification") {
            try withFixture { paths, fixture in
                let backend = InMemorySettingsBackend()
                let store = SherpaImportedPresetStore(backend: backend)
                let record = SherpaImportedPresetRecord(id: "active-import", language: "en-US", extractedDirName: fixture.extractedDirName, sizeMB: 0, importedAt: Date())
                try expect(store.add(record))
                let preset = store.presets()[0]
                try model(at: paths.model(preset))
                backend.set(preset.id, forKey: AppSettings.Keys.sherpaModelPresetID)
                let selection = SherpaModelSelection(backend: backend, importedStore: store, memoryBytes: 8 * 1024 * 1024 * 1024)
                var keys: [String] = []
                let token = NotificationCenter.default.addObserver(forName: AppSettingsEventBus.recognitionEngineNotification, object: backend, queue: nil) { notification in
                    if case .recognitionEngineSettingsChanged(let key) = AppSettingsEventBus.decode(notification) { keys.append(key) }
                }
                defer { NotificationCenter.default.removeObserver(token) }
                try SherpaResourceInstaller.removeModel(preset, paths: paths, store: store, selection: selection)
                try expect(backend.string(forKey: AppSettings.Keys.sherpaModelPresetID) == "en-20M")
                try expect(keys == [AppSettings.Keys.sherpaModelPresetID])
                try expect(store.records.isEmpty && !FileManager.default.fileExists(atPath: paths.model(preset).path))
            }
        }
        await runner.run("Sherpa deleting imported model restores directory when record save fails") {
            try withFixture { paths, fixture in
                let preset = SherpaModelPreset(id: "fixture", language: "en-US", archiveURL: nil, archiveName: nil,
                    extractedDirName: fixture.extractedDirName, sizeMB: 0, isImported: true)
                try model(at: paths.model(preset))
                let backend = RejectingSherpaBackend()
                let store = SherpaImportedPresetStore(backend: backend)
                do {
                    try SherpaResourceInstaller.removeModel(preset, paths: paths, store: store,
                        selection: SherpaModelSelection(backend: backend, importedStore: store))
                    throw TestFailure(file: #filePath, line: #line, message: "Rejected store must fail delete")
                } catch is CocoaError {}
                try expect(ModelManifest.inspect(in: paths.model(preset)) != nil)
            }
        }
        await runner.run("Sherpa runtime update replaces usable old libraries and writes matching version") {
            try withFixture { paths, preset in
                try readyRuntime(paths)
                let version = "v-fixture"
                let source = paths.support.appendingPathComponent("archive-source")
                let root = source.appendingPathComponent(SherpaModelDownloader.runtimeArchiveRootName(for: version))
                for name in SherpaResourcePaths.runtimeLibraries { try write("new-library", at: root.appendingPathComponent("lib/" + name)) }
                let archive = paths.support.appendingPathComponent("runtime.tar.bz2")
                try tar(source: source, archive: archive)
                let item = SherpaDownloadItem(kind: .runtime, urlCandidates: [], archiveName: "runtime.tar.bz2")
                let installed = try SherpaDownloadInstallation(paths: paths).install(archive: archive, item: item, preset: preset, version: version, attempt: SherpaInstallAttempt())
                try expect(installed)
                for name in SherpaResourcePaths.runtimeLibraries {
                    try expect((try? String(contentsOf: paths.runtime.appendingPathComponent(name))) == "new-library")
                }
                try expect((try? String(contentsOf: paths.version)) == version)
            }
        }
        await runner.run("Sherpa cancelled attempt cannot replace model after extraction") {
            try withFixture { paths, preset in
                try model(at: paths.model(preset))
                try write("old", at: paths.model(preset).appendingPathComponent("marker"))
                let source = paths.support.appendingPathComponent("archive-source")
                try model(at: source)
                let archive = paths.support.appendingPathComponent("model.tar.bz2")
                try tar(source: source, archive: archive)
                let attempt = SherpaInstallAttempt()
                attempt.cancel()
                let installed = try SherpaDownloadInstallation(paths: paths).install(archive: archive,
                    item: .init(kind: .asr, urlCandidates: [], archiveName: "model.tar.bz2"), preset: preset, version: "fixture", attempt: attempt)
                try expect(!installed)
                try expect((try? String(contentsOf: paths.model(preset).appendingPathComponent("marker"))) == "old")
                var oldCommitted = false
                _ = attempt.commit { oldCommitted = true }
                try expect(!oldCommitted)
                let replacement = SherpaInstallAttempt()
                try expect(replacement.commit { true } == true)
            }
        }
        await runner.run("Sherpa cancellation stays responsive during blocked model preparation and prevents commit") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoice-SherpaBlockedPreparation-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = SherpaResourcePaths(support: root)
            let preset = SherpaModelPreset.builtInPresets[0]
            try model(at: paths.model(preset))
            try write("old", at: paths.model(preset).appendingPathComponent("marker"))
            let source = root.appendingPathComponent("source")
            try model(at: source)
            let archive = root.appendingPathComponent("model.tar.bz2")
            try tar(source: source, archive: archive)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            let installer = SherpaDownloadInstallation(paths: paths, copyDirectory: { source, target in
                entered.signal()
                release.wait()
                try FileManager.default.copyItem(at: source, to: target)
            })
            let attempt = SherpaInstallAttempt()
            let work = Task.detached {
                try installer.install(archive: archive, item: .init(kind: .asr, urlCandidates: [], archiveName: "model.tar.bz2"),
                    preset: preset, version: "fixture", attempt: attempt)
            }
            let didEnter = await waitForSignal(entered, timeout: 2)
            try expect(didEnter)
            let cancellationObserved = Task.detached {
                let responsive = await waitForSignal(cancelled, timeout: 0.5)
                release.signal()
                return responsive
            }
            await MainActor.run { attempt.cancel(); cancelled.signal() }
            let responsive = await cancellationObserved.value
            let installed = try await work.value
            try expect(responsive && !installed)
            try expect((try? String(contentsOf: paths.model(preset).appendingPathComponent("marker"))) == "old")
        }
        await runner.run("Sherpa cancel before version response isolates next attempt observers and stale delegates") {
            var callbacks: [(String) -> Void] = []
            let downloader = SherpaModelDownloader(fetchVersion: { callbacks.append($0) })
            var completions: [String] = []
            downloader.addObserver(complete: { _, _ in completions.append("old") })
            try expect(downloader.startDownload() == .started)
            downloader.cancel()
            downloader.addObserver(complete: { _, _ in completions.append("new") })
            try expect(downloader.startDownload() == .started)
            callbacks[0]("stale")
            let session = URLSession(configuration: .ephemeral)
            let task = session.downloadTask(with: URL(string: "https://fixture.invalid")!)
            downloader.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: 1, totalBytesExpectedToWrite: 1)
            downloader.urlSession(session, task: task, didCompleteWithError: URLError(.cannotConnectToHost))
            try await waitForAsyncCallbacks()
            try expect(downloader.isDownloading && completions == ["old"])
            downloader.cancel()
            session.invalidateAndCancel()
            try expect(completions == ["old", "new"])
        }
        await runner.run("Sherpa selection uses supplied store language and memory defaults") {
            let backend = InMemorySettingsBackend()
            backend.set("en-US", forKey: AppSettings.Keys.selectedLanguage)
            let store = SherpaImportedPresetStore(backend: backend)
            let selection = SherpaModelSelection(backend: backend, importedStore: store, memoryBytes: 8 * 1024 * 1024 * 1024)
            try expect(selection.current.id == "en-20M")
            let record = SherpaImportedPresetRecord(id: "custom-de", language: "de-DE", extractedDirName: "fixture", sizeMB: 0, importedAt: Date())
            try expect(store.add(record))
            try expect(selection.defaultModelID(for: "de-DE") == "custom-de")
            backend.set("custom-de", forKey: AppSettings.Keys.sherpaModelPresetID)
            try expect(selection.current.id == "custom-de")
        }
    }

    private static func withFixture(_ work: (SherpaResourcePaths, SherpaModelPreset) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoice-SherpaResourceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let preset = SherpaModelPreset(id: "fixture", language: "en-US", archiveURL: URL(string: "https://fixture.invalid/model.tar.bz2"),
            archiveName: "model.tar.bz2", extractedDirName: "fixture-model", sizeMB: 0, isImported: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try work(.init(support: root), preset)
    }
    private static func model(at directory: URL) throws {
        for name in ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"] { try write("fixture", at: directory.appendingPathComponent(name)) }
    }
    private static func readyRuntime(_ paths: SherpaResourcePaths) throws {
        for name in SherpaResourcePaths.runtimeLibraries { try write("old-library", at: paths.runtime.appendingPathComponent(name)) }
    }
    private static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private static func tar(source: URL, archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archive.path, "-C", source.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class RejectingSherpaBackend: SettingsBackend {
    let storage = InMemorySettingsBackend()
    var notificationObject: Any? { nil }
    func string(forKey key: String) -> String? { storage.string(forKey: key) }
    func string(forKey key: String, default value: String) -> String { storage.string(forKey: key, default: value) }
    func bool(forKey key: String, default value: Bool) -> Bool { storage.bool(forKey: key, default: value) }
    func double(forKey key: String, default value: Double) -> Double { storage.double(forKey: key, default: value) }
    func integer(forKey key: String, default value: Int) -> Int { storage.integer(forKey: key, default: value) }
    func data(forKey key: String) -> Data? { storage.data(forKey: key) }
    func set(_ value: Any?, forKey key: String) {}
    func register(defaults: [String: Any]) { storage.register(defaults: defaults) }
    func observe(key: String, handler: @escaping () -> Void) -> SettingsObservation { storage.observe(key: key, handler: handler) }
}
