import Cocoa
import Darwin
import Foundation

#if DEBUG_BUILD
@testable import AtomVoiceCore

private enum CheckStatus: String, Codable {
    case ok
    case warn
    case fail
}

private struct DoctorCheck: Codable {
    let check: String
    let status: CheckStatus
    let detail: String
    let metadata: [String: String]?
}

private struct DoctorReport: Codable {
    let ok: Bool
    let generatedAt: String
    let environment: [String: String]
    let checks: [DoctorCheck]
    let warnings: [String]
    let errors: [String]
}

private struct DoctorOptions {
    var prettyPrinted = true
    var showHelp = false
    var hasInvalidOption = false
}

private final class AtomVoiceDoctor {
    private let fileManager = FileManager.default
    private let rootURL: URL
    private var checks: [DoctorCheck] = []

    init(rootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
        self.rootURL = rootURL
    }

    func run() -> DoctorReport {
        AppSettings.registerDefaults()

        checkSourceTree()
        checkToolchain()
        checkAppMetadata()
        checkCurrentSettings()
        checkPermissions()
        checkSherpaFiles()
        checkUpdateSettings()
        checkDebugLog()
        checkFrontmostPasteProfile()

        let errors = checks
            .filter { $0.status == .fail }
            .map { "\($0.check): \($0.detail)" }
        let warnings = checks
            .filter { $0.status == .warn }
            .map { "\($0.check): \($0.detail)" }

        return DoctorReport(
            ok: errors.isEmpty,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            environment: environmentSnapshot(),
            checks: checks,
            warnings: warnings,
            errors: errors
        )
    }

    private func add(
        _ check: String,
        _ status: CheckStatus,
        _ detail: String,
        metadata: [String: String] = [:]
    ) {
        checks.append(DoctorCheck(
            check: check,
            status: status,
            detail: detail,
            metadata: metadata.isEmpty ? nil : metadata
        ))
    }

    private func checkSourceTree() {
        let packageURL = rootURL.appendingPathComponent("Package.swift")
        let infoURL = atomVoiceInfoPlistURL()
        let hasPackage = fileManager.fileExists(atPath: packageURL.path)
        let hasInfo = fileManager.fileExists(atPath: infoURL.path)

        if hasPackage && hasInfo {
            add("source tree", .ok, "Package.swift and AtomVoice Info.plist found", metadata: [
                "root": rootURL.path,
                "infoPlist": relativePath(infoURL),
            ])
        } else {
            add("source tree", .fail, "Run AtomVoiceDoctor from the repository root", metadata: [
                "root": rootURL.path,
                "packageExists": String(hasPackage),
                "infoPlistExists": String(hasInfo),
            ])
        }
    }

    private func checkToolchain() {
        let xcodeSelect = runCommand("/usr/bin/xcode-select", ["-p"])
        let swiftVersion = runCommand("/usr/bin/xcrun", ["swift", "--version"])
        var metadata: [String: String] = [:]
        if xcodeSelect.status == 0 {
            metadata["xcodeSelect"] = xcodeSelect.stdout.trimmedSingleLine()
        } else {
            metadata["xcodeSelectError"] = xcodeSelect.stderr.trimmedSingleLine()
        }
        if swiftVersion.status == 0 {
            metadata["swift"] = swiftVersion.stdout.trimmedSingleLine()
        } else {
            metadata["swiftError"] = swiftVersion.stderr.trimmedSingleLine()
        }

        let ok = xcodeSelect.status == 0 && swiftVersion.status == 0
        add(
            "toolchain",
            ok ? .ok : .warn,
            ok ? "Swift toolchain is discoverable" : "Could not fully inspect the Swift toolchain",
            metadata: metadata
        )
    }

    private func checkAppMetadata() {
        let expectedBundleID = "com.blacksquarre.AtomVoice"
        guard let info = readInfoPlist() else {
            add("app metadata", .fail, "Unable to read Sources/AtomVoice/Info.plist")
            return
        }

        let bundleID = info["CFBundleIdentifier"] ?? ""
        let version = info["CFBundleShortVersionString"] ?? ""
        let build = info["CFBundleVersion"] ?? ""
        let localizations = info["CFBundleLocalizations"] ?? ""

        if bundleID != expectedBundleID || version.isEmpty || build.isEmpty {
            add("app metadata", .fail, "Info.plist metadata is incomplete or unexpected", metadata: [
                "bundleIdentifier": bundleID,
                "expectedBundleIdentifier": expectedBundleID,
                "version": version,
                "build": build,
            ])
            return
        }

        add("app metadata", .ok, "Info.plist metadata matches update expectations", metadata: [
            "bundleIdentifier": bundleID,
            "version": version,
            "build": build,
            "localizations": localizations,
        ])
    }

    private func checkCurrentSettings() {
        let rawEngine = AppSettings.recognitionEngine
        let normalizedEngine = AppSettings.normalizedRecognitionEngine
        let descriptor = ASREngineRegistry.shared.descriptor(for: normalizedEngine)
        let textOutput = AppSettings.backend.string(forKey: TextOutputSinkRegistry.settingsKey) ?? TextOutputSinkRegistry.pasteCode

        let status: CheckStatus = rawEngine == normalizedEngine ? .ok : .warn
        let detail = rawEngine == normalizedEngine
            ? "Recognition settings are valid"
            : "Recognition engine setting will fall back to \(normalizedEngine)"

        add("current settings", status, detail, metadata: [
            "selectedLanguage": AppSettings.selectedLanguage,
            "recognitionEngine": rawEngine,
            "normalizedRecognitionEngine": normalizedEngine,
            "engineRequiresCredential": String(descriptor?.requiresCredential ?? false),
            "textOutputSink": textOutput,
            "pasteDelay": String(format: "%.2f", AppSettings.pasteDelay),
            "audioInputDeviceUID": AppSettings.audioInputDeviceUID.isEmpty ? "(default)" : AppSettings.audioInputDeviceUID,
            "oobeCompleted": String(AppSettings.hasCompletedOOBE),
            "headphoneControlEnabled": String(AppSettings.headphoneControlEnabled),
        ])
    }

    private func checkPermissions() {
        let service = PermissionService.shared
        let accessibility = statusName(service.status(for: .accessibility))
        let microphone = statusName(service.status(for: .microphone))
        let speech = statusName(service.status(for: .speechRecognition))
        let allGranted = accessibility == "granted" && microphone == "granted" && speech == "granted"

        add(
            "permissions",
            allGranted ? .ok : .warn,
            allGranted
                ? "Current process has required permissions"
                : "Permission status is for this diagnostic process; packaged app permissions may differ",
            metadata: [
                "accessibility": accessibility,
                "microphone": microphone,
                "speechRecognition": speech,
            ]
        )
    }

    private func checkSherpaFiles() {
        let preset = SherpaModelPreset.current
        let runtimeFiles = SherpaModelDownloader.runtimeRequiredFiles()
        let missingRuntime = runtimeFiles
            .filter { !SherpaModelPreset.isUsableFile($0.url) }
            .map(\.name)
        let hasManifest = preset.resolveManifest() != nil
        let punctuationURL = SherpaModelDownloader.punctuationRequiredFile()
        let hasPunctuation = SherpaModelPreset.isUsableFile(punctuationURL)
        let ready = missingRuntime.isEmpty && hasManifest && hasPunctuation
        let selectedSherpa = ASREngineRegistry.shared.isSherpa(AppSettings.normalizedRecognitionEngine)

        var missing: [String] = missingRuntime.map { "runtime:\($0)" }
        if !hasManifest { missing.append("model-manifest") }
        if !hasPunctuation { missing.append("punctuation:model.int8.onnx") }

        let status: CheckStatus
        if ready {
            status = .ok
        } else if selectedSherpa {
            status = .fail
        } else {
            status = .warn
        }

        add(
            "sherpa files",
            status,
            ready
                ? "Sherpa runtime, ASR model, and punctuation model are present"
                : "Sherpa files are missing: \(missing.joined(separator: ", "))",
            metadata: [
                "selectedEngine": AppSettings.normalizedRecognitionEngine,
                "presetID": preset.id,
                "presetLanguage": preset.language,
                "provider": AppSettings.sherpaProvider,
                "runtimeVersion": SherpaModelDownloader.getLocalRuntimeVersion(),
                "supportDirectory": SherpaOnnxRecognizerController.supportDirectory.path,
                "modelDirectory": preset.modelDirectory.path,
                "punctuationPath": punctuationURL.path,
            ]
        )
    }

    private func checkUpdateSettings() {
        add("update settings", .ok, "Update preferences read without network access", metadata: [
            "includeBetaUpdates": String(AppSettings.includeBetaUpdates),
            "updateToDebugBuilds": String(AppSettings.updateToDebugBuilds),
        ])
    }

    private func checkDebugLog() {
        let logURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AtomVoice/debug.log")
        let logDir = logURL.deletingLastPathComponent()
        let dirExists = fileManager.fileExists(atPath: logDir.path)
        let fileExists = fileManager.fileExists(atPath: logURL.path)
        let size = fileSize(at: logURL)

        add(
            "debug log",
            dirExists ? .ok : .warn,
            dirExists ? "Debug log directory is present" : "Debug log directory has not been created yet",
            metadata: [
                "path": logURL.path,
                "exists": String(fileExists),
                "sizeBytes": size.map(String.init) ?? "0",
            ]
        )
    }

    private func checkFrontmostPasteProfile() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            add("frontmost paste profile", .warn, "No frontmost application was available")
            return
        }

        let profile = PasteCompatibilityRegistry.profileForFrontmostApp()
        var metadata = [
            "frontmostName": app.localizedName ?? "(unknown)",
            "frontmostBundleID": app.bundleIdentifier ?? "(none)",
        ]
        if let profile {
            metadata["profileDisplayName"] = profile.displayName
            metadata["profileCategory"] = categoryName(profile.category)
            metadata["pasteDelay"] = String(format: "%.2f", profile.pasteDelay)
            add("frontmost paste profile", .ok, "Frontmost app matches a paste compatibility profile", metadata: metadata)
        } else {
            add("frontmost paste profile", .ok, "Frontmost app uses default paste behavior", metadata: metadata)
        }
    }

    private func environmentSnapshot() -> [String: String] {
        let swiftVersion = runCommand("/usr/bin/xcrun", ["swift", "--version"]).stdout.trimmedSingleLine()
        let xcodePath = runCommand("/usr/bin/xcode-select", ["-p"]).stdout.trimmedSingleLine()
        return [
            "cwd": rootURL.path,
            "hostName": ProcessInfo.processInfo.hostName,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": machineArchitecture(),
            "physicalMemoryGB": String(format: "%.1f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0),
            "developerDir": ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "",
            "xcodeSelect": xcodePath,
            "swift": swiftVersion,
        ]
    }

    private func atomVoiceInfoPlistURL() -> URL {
        rootURL.appendingPathComponent("Sources/AtomVoice/Info.plist")
    }

    private func readInfoPlist() -> [String: String]? {
        guard let data = try? Data(contentsOf: atomVoiceInfoPlistURL()),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any] else {
            return nil
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            } else if let strings = value as? [String] {
                result[key] = strings.joined(separator: ",")
            }
        }
        return result
    }

    private func relativePath(_ url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private func statusName(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        }
    }

    private func categoryName(_ category: PasteCompatibilityCategory) -> String {
        switch category {
        case .remoteDesktop: return "remoteDesktop"
        case .virtualMachine: return "virtualMachine"
        case .gameStreaming: return "gameStreaming"
        case .electron: return "electron"
        }
    }

    private func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let bytes = mirror.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }

    private func runCommand(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

private extension String {
    func trimmedSingleLine() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private func parseOptions() -> DoctorOptions {
    var options = DoctorOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--json", "--pretty":
            options.prettyPrinted = true
        case "--compact":
            options.prettyPrinted = false
        case "--help", "-h":
            options.showHelp = true
        default:
            fputs("Unknown option: \(arg)\n", stderr)
            options.showHelp = true
            options.hasInvalidOption = true
        }
    }
    return options
}

private func printHelp() {
    print("""
    AtomVoiceDoctor

    Usage:
      AtomVoiceDoctor --json
      AtomVoiceDoctor --compact

    The default checks are read-only: no permission prompts, no recording,
    no model downloads, and no cloud ASR requests.
    """)
}

private let options = parseOptions()
if options.showHelp {
    printHelp()
    exit(options.hasInvalidOption ? 1 : 0)
}

private let report = AtomVoiceDoctor().run()
private let encoder = JSONEncoder()
encoder.outputFormatting = options.prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]

do {
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(report.ok ? 0 : 1)
} catch {
    fputs("Failed to encode doctor report: \(error)\n", stderr)
    exit(1)
}
#else
fputs("AtomVoiceDoctor is available only in DEBUG_BUILD.\n", stderr)
exit(1)
#endif
