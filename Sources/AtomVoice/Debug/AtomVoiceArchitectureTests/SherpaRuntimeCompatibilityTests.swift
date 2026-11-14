import AppKit
import Foundation
@testable import AtomVoiceCore

enum SherpaRuntimeCompatibilityTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Sherpa common resolver accepts generic and legacy names without loading libraries") {
            for name in ["libonnxruntime.dylib", "libonnxruntime.1.24.4.dylib", "libonnxruntime.1.27.0.dylib"] {
                try fixture { paths in
                    try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent(name))
                    try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                    let layout = try require(SherpaRuntimeLayout.resolve(in: paths.runtime))
                    try expect(layout.onnx.lastPathComponent == name)
                    try expect(SherpaResources(paths: paths, operatingSystemVersion: os(27)).runtimeReady)
                }
            }
        }
        await runner.run("Sherpa resolver ignores empty generic library and rejects external symlink") {
            try fixture { paths in
                try write("", to: paths.runtime.appendingPathComponent("libonnxruntime.dylib"))
                try write("fixture", to: paths.runtime.appendingPathComponent("libonnxruntime.1.24.4.dylib"))
                try write("fixture", to: paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                try expect(SherpaRuntimeLayout.resolve(in: paths.runtime)?.onnx.lastPathComponent == "libonnxruntime.1.24.4.dylib")
                try FileManager.default.removeItem(at: paths.runtime.appendingPathComponent("libonnxruntime.dylib"))
                let outside = paths.support.appendingPathComponent("outside")
                try write("fixture", to: outside)
                try FileManager.default.createSymbolicLink(at: paths.runtime.appendingPathComponent("libonnxruntime.dylib"), withDestinationURL: outside)
                try expect(SherpaRuntimeLayout.resolve(in: paths.runtime) == nil)
            }
        }
        await runner.run("Sherpa checks binary requirements instead of pinning old systems to version numbers") {
            for old in [os(14), os(15), os(15, 4)] { try expect(SherpaRuntimeRelease.requiresVersionRestriction(on: old)) }
            for current in [os(15, 5), os(26), os(27)] { try expect(SherpaRuntimeRelease.compatibilityNotice(on: current) == nil) }
            try fixture { paths in
                try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                try writeBinary(minimum: os(15, 5), to: paths.runtime.appendingPathComponent("libonnxruntime.dylib"))
                try write("v1.13.7", to: paths.version)
                try expect(!SherpaResources(paths: paths, operatingSystemVersion: os(14)).runtimeReady)
                try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent("libonnxruntime.dylib"))
                try write("v9.9.9", to: paths.version)
                try expect(SherpaResources(paths: paths, operatingSystemVersion: os(14)).runtimeReady)
            }
        }
        await runner.run("Sherpa latest metadata accepts future releases and requires matching official asset digest") {
            let version = "v9.9.9"
            let asset: [String: Any] = ["name": SherpaModelDownloader.runtimeArchiveRootName(for: version) + ".tar.bz2",
                                       "size": 123, "digest": "sha256:" + String(repeating: "a", count: 64)]
            let body: [String: Any] = ["tag_name": version, "draft": false, "prerelease": false, "assets": [asset]]
            let parsed = try SherpaRuntimeRelease.fromLatestResponse(JSONSerialization.data(withJSONObject: body))
            try expect(parsed.version == version && parsed.size == 123)
            var missing = body
            missing["assets"] = [["name": asset["name"]!, "size": 123]]
            do {
                _ = try SherpaRuntimeRelease.fromLatestResponse(JSONSerialization.data(withJSONObject: missing))
                throw TestFailure(file: #filePath, line: #line, message: "Missing digest accepted")
            } catch SherpaRuntimeInstallError.releaseMetadata {}
            var prerelease = body
            prerelease["prerelease"] = true
            do {
                _ = try SherpaRuntimeRelease.fromLatestResponse(JSONSerialization.data(withJSONObject: prerelease))
                throw TestFailure(file: #filePath, line: #line, message: "Prerelease accepted")
            } catch SherpaRuntimeInstallError.releaseMetadata {}
        }
        await runner.run("Sherpa Mach-O inspection rejects truncation and wrong architecture") {
            try fixture { paths in
                let file = paths.support.appendingPathComponent("binary")
                try writeBinary(minimum: os(11), to: file, cpu: 0x1234)
                try expect(!SherpaRuntimeBinary.supports(file, on: os(27)))
                try write("short", to: file)
                try expect(!SherpaRuntimeBinary.supports(file, on: os(27)))
            }
        }
        await runner.run("Sherpa repair never fills a recorded runtime from another version") {
            try fixture { paths in
                try write("v2.0.0", to: paths.version)
                try write("keep", to: paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                let lib = paths.support.appendingPathComponent(SherpaModelDownloader.runtimeArchiveRootName(for: "v2.0.1") + "/lib")
                for name in SherpaResourcePaths.runtimeLibraries { try write("other", to: lib.appendingPathComponent(name)) }
                try SherpaResources(paths: paths).repairRuntimeIfNeeded()
                try expect(!FileManager.default.fileExists(atPath: paths.runtime.appendingPathComponent("libonnxruntime.dylib").path))
            }
        }
        await runner.run("Sherpa archive verification binds size and checksum to fetched release metadata") {
            try fixture { paths in
                let archive = paths.support.appendingPathComponent("runtime.tar.bz2")
                try write("abc", to: archive)
                let release = SherpaRuntimeRelease(version: "v9.9.9", size: 3,
                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                try release.verifyArchive(archive)
                try write("abd", to: archive)
                do {
                    try release.verifyArchive(archive)
                    throw TestFailure(file: #filePath, line: #line, message: "Corrupt digest accepted")
                } catch SherpaRuntimeInstallError.integrity {}
                try write("<html>upstream error</html>", to: archive)
                do {
                    try release.verifyArchive(archive)
                    throw TestFailure(file: #filePath, line: #line, message: "Wrong size accepted")
                } catch SherpaRuntimeInstallError.integrity {}
            }
        }
        await runner.run("Sherpa corrupted tar reports extraction diagnostic and preserves old install") {
            try fixture { paths in
                try write("keep", to: paths.runtime.appendingPathComponent("marker"))
                let archive = paths.support.appendingPathComponent("invalid.tar.bz2")
                try write("not a tar", to: archive)
                do {
                    _ = try SherpaDownloadInstallation(paths: paths, verifyRuntimeArchive: { _, _ in }).install(
                        archive: archive, item: .init(kind: .runtime, urlCandidates: [], archiveName: "runtime.tar.bz2"),
                        preset: SherpaModelPreset.builtInPresets[0], version: "v2.0.1", attempt: SherpaInstallAttempt())
                    throw TestFailure(file: #filePath, line: #line, message: "Corrupt tar accepted")
                } catch SherpaRuntimeInstallError.extraction(let detail) {
                    try expect(detail.contains("exit="))
                }
                try expect((try? String(contentsOf: paths.runtime.appendingPathComponent("marker"))) == "keep")
            }
        }
        await runner.run("Sherpa runtime update rolls back cached archive when live directory commit fails") {
            try fixture { paths in
                let version = "v2.0.1"
                let rootName = SherpaModelDownloader.runtimeArchiveRootName(for: version)
                let source = paths.support.appendingPathComponent("source")
                let lib = source.appendingPathComponent(rootName + "/lib")
                try writeBinary(minimum: os(11), to: lib.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                try writeBinary(minimum: os(11), to: lib.appendingPathComponent("libonnxruntime.dylib"))
                try write("old-runtime", to: paths.runtime.appendingPathComponent("marker"))
                try write("v-old", to: paths.version)
                let cachedMarker = paths.support.appendingPathComponent(rootName + "/marker")
                try write("old-cache", to: cachedMarker)
                let archive = paths.support.appendingPathComponent("runtime.tar.bz2")
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-cjf", archive.path, "-C", source.path, rootName]
                try tar.run(); tar.waitUntilExit()
                try expect(tar.terminationStatus == 0)
                var commits = 0
                let installer = SherpaDownloadInstallation(paths: paths, verifyRuntimeArchive: { _, _ in }, installPrepared: {
                    commits += 1
                    if commits == 2 { throw CocoaError(.fileWriteNoPermission) }
                    return try $0.install()
                })
                do {
                    _ = try installer.install(archive: archive,
                        item: .init(kind: .runtime, urlCandidates: [], archiveName: "runtime.tar.bz2"),
                        preset: SherpaModelPreset.builtInPresets[0], version: version, attempt: SherpaInstallAttempt())
                    throw TestFailure(file: #filePath, line: #line, message: "Injected commit failure ignored")
                } catch is CocoaError {}
                try expect((try? String(contentsOf: cachedMarker)) == "old-cache")
                try expect((try? String(contentsOf: paths.version)) == "v-old")
                try expect((try? String(contentsOf: paths.runtime.appendingPathComponent("marker"))) == "old-runtime")
            }
        }
        await runner.run("Sherpa runtime request cannot subscribe to another model download as update success") {
            let downloader = SherpaModelDownloader(fetchRelease: { _ in })
            _ = downloader.startDownload()
            var completions = 0
            let coordinator = SherpaDownloadCoordinator(downloader: downloader, reporter: nil)
            try expect(coordinator.start(runtimeOnly: true, completion: { _, _ in completions += 1 }) == .alreadyDownloading)
            downloader.cancel()
            try expect(completions == 0)
        }
        await runner.run("Sherpa confirmed release snapshot is reused without a second latest query") {
            try await fixtureAsync { paths in
                let preset = SherpaModelPreset.builtInPresets[0]
                for name in ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"] {
                    try write("fixture", to: paths.model(preset).appendingPathComponent(name))
                }
                try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent(SherpaRuntimeLayout.sherpaLibrary))
                try writeBinary(minimum: os(11), to: paths.runtime.appendingPathComponent("libonnxruntime.dylib"))
                try write("fixture", to: paths.punctuation.appendingPathComponent("model.int8.onnx"))
                var queries = 0
                var completed = false
                let downloader = SherpaModelDownloader(paths: paths, fetchRelease: { _ in queries += 1 })
                downloader.addObserver(complete: { success, _ in completed = success })
                _ = downloader.startDownload(preset: preset, runtimeRelease: SherpaRuntimeRelease.knownCompatible[0])
                try await waitForAsyncCallbacks()
                try expect(queries == 0 && completed)
                completed = false
                downloader.addObserver(complete: { success, _ in completed = success })
                _ = downloader.startDownload(preset: preset)
                try await waitForAsyncCallbacks()
                try expect(queries == 0 && completed)
            }
        }
        await runner.run("Sherpa settings show compatibility list on old systems and hide it on new systems") {
            try await MainActor.run {
                for (version, hidden) in [(os(14), false), (os(15, 4), false), (os(15, 5), true), (os(27), true)] {
                    let tab = SherpaSettingsTab(parentWindow: { nil }, onStatusChanged: { _, _ in },
                        sherpaDownloadReporter: nil, operatingSystemVersion: version)
                    let page = tab.makeView()
                    @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    let label = try require(descendants(page).first { $0.identifier?.rawValue == "sherpa.runtime.compatibility" } as? NSTextField)
                    try expect(label.isHidden == hidden)
                    try expect(page is NSScrollView)
                }
            }
        }
        await runner.run("Sherpa compatibility list is translated in all eight languages") {
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"] {
                let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
                let strings = try require(NSDictionary(contentsOf: url) as? [String: String])
                let template = try require(strings["sherpa.runtime.compatibilityNotice"])
                let versions = SherpaRuntimeRelease.knownCompatible.map { "• " + $0.version }.joined(separator: "\n")
                let message = String(format: template, versions)
                for release in SherpaRuntimeRelease.knownCompatible { try expect(message.contains(release.version)) }
            }
        }
        await runner.run("Sherpa settings keep content packed at the top after refresh and viewport resizing") {
            try await MainActor.run {
                for version in [os(14), os(27)] {
                    let tab = SherpaSettingsTab(parentWindow: { nil }, onStatusChanged: { _, _ in },
                        sherpaDownloadReporter: nil, operatingSystemVersion: version)
                    let scroll = try require(tab.makeView() as? NSScrollView)
                    let document = try require(scroll.documentView)
                    let header = try require(document.subviews.first { $0.identifier?.rawValue == "sherpa.settings.header" } as? NSStackView)
                    let controls = try require(document.subviews.first { $0.identifier?.rawValue == "sherpa.settings.controls" })
                    for height: CGFloat in [900, 340, 1100] {
                        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: height)
                        tab.refreshStatus()
                        scroll.layoutSubtreeIfNeeded()
                        document.layoutSubtreeIfNeeded()
                        let visibleLabels = header.arrangedSubviews.filter { !$0.isHidden }
                        let lastLabel = try require(visibleLabels.last)
                        let labelBottom = document.convert(lastLabel.bounds, from: lastLabel).maxY
                        // 顶部说明不能吸收视口余量，控件始终紧跟最后一行说明。
                        let gap = controls.frame.minY - labelBottom
                        try expect(abs(gap - 12) < 2, "Unexpected header gap: \(gap), viewport: \(height)")
                        try expect(document.frame.height < 900, "Document stretches to viewport: \(document.frame.height)")
                        if height == 340 {
                            try expect(document.frame.height > scroll.contentSize.height, "Long content must remain scrollable")
                        }
                    }
                }
            }
        }
        // 可选公开包 fixture 只验证本地安装，不联网、不 dlopen、不加载模型。
        if let directory = ProcessInfo.processInfo.environment["ATOMVOICE_SHERPA_RUNTIME_FIXTURES"] {
            for release in SherpaRuntimeRelease.knownCompatible {
                await runner.run("Sherpa verified official archive installs on isolated fixture: \(release.version)") {
                    try fixture { paths in
                        let archive = URL(fileURLWithPath: directory).appendingPathComponent("\(release.version)/runtime.tar.bz2")
                        let model = paths.models.appendingPathComponent("preserve-model")
                        try write("keep-model", to: model)
                        let installed = try SherpaDownloadInstallation(paths: paths).install(archive: archive,
                            item: .init(kind: .runtime, urlCandidates: [], archiveName: "runtime.tar.bz2", runtimeRelease: release),
                            preset: SherpaModelPreset.builtInPresets[0], version: release.version, attempt: SherpaInstallAttempt())
                        try expect(installed)
                        try expect(SherpaResources(paths: paths, operatingSystemVersion: os(14)).runtimeReady)
                        try expect((try? String(contentsOf: paths.version)) == release.version)
                        try expect((try? String(contentsOf: model)) == "keep-model")
                    }
                }
            }
        }
    }

    private static func writeBinary(minimum: OperatingSystemVersion, to url: URL, cpu: UInt32 = SherpaRuntimeBinary.currentCPU) throws {
        let version = UInt32(minimum.majorVersion << 16 | minimum.minorVersion << 8 | minimum.patchVersion)
        let words: [UInt32] = [0xfeedfacf, cpu, 0, 6, 1, 24, 0, 0, 0x32, 24, 1, version, version, 0]
        var data = Data()
        for word in words { var little = word.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private static func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        .init(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }
    private static func fixture(_ work: (SherpaResourcePaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoice-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try work(SherpaResourcePaths(support: root))
    }
    private static func fixtureAsync(_ work: (SherpaResourcePaths) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoice-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await work(SherpaResourcePaths(support: root))
    }
    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
