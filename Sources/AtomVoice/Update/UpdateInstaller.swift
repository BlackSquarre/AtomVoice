import Cocoa
import CryptoKit
import Security

/// 安装阶段的错误类型；编码进 UpdateError 的子集，覆盖校验、解压、签名、安装。
/// (Error type for the install stage; covers checksum verification, unzip, signature, install.)
enum UpdateInstallError: LocalizedError, Equatable {
    case unzipFailed(Int32)
    case appNotFound
    case zipListingFailed(Int32)
    case invalidZipEntry(String)
    case invalidBundle(String)
    case signatureInvalid(String)
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let code): return "unzip failed (exit code \(code))"
        case .appNotFound: return "No .app bundle found in zip"
        case .zipListingFailed(let code): return "zip listing failed (exit code \(code))"
        case .invalidZipEntry(let entry): return "Unsafe zip entry: \(entry)"
        case .invalidBundle(let reason): return "Downloaded app is invalid: \(reason)"
        case .signatureInvalid(let reason): return "Downloaded app signature is invalid: \(reason)"
        case .checksumMissing(let asset): return "SHA256 entry missing for \(asset)"
        case .checksumMismatch(let expected, let actual):
            return "SHA256 mismatch (expected \(expected), got \(actual))"
        }
    }
}

/// 安装阶段的纯本地操作接口：校验、解压、签名、relaunch；与下载/UI 解耦。
/// (Install-stage local-only operations: verify, unzip, signature, relaunch; decoupled from download/UI.)
protocol UpdateInstaller: AnyObject {
    /// 同步校验 SHA256；失败抛 UpdateInstallError。
    /// (Synchronously verify SHA256; throws UpdateInstallError on failure.)
    func verifyChecksum(zipURL: URL, listing: String, assetName: String) throws

    /// 同步解压 zip，返回解压出的 .app URL。
    /// (Synchronously unzip; returns the URL of the extracted .app bundle.)
    func extractZip(_ zipURL: URL) throws -> URL

    /// 同步校验 .app 的 bundle id、版本、代码签名。
    /// (Synchronously validate the .app's bundle id, version, and code signature.)
    func validateDownloadedApp(_ appURL: URL, currentVersion: String, expectedVersion: String) throws

    /// 写脚本 + exec 替换 .app + relaunch；终止当前进程交由 caller。
    /// (Write the relaunch script and exec it; the caller is responsible for terminating the current process.)
    func applyAndRelaunch(newAppURL: URL, currentBundlePath: String) throws
}

/// 默认实现，按指定 bundleIdentifier/teamIdentifier 校验签名。
/// (Default implementation; validates code signature against the given bundleIdentifier/teamIdentifier.)
final class BundleUpdateInstaller: UpdateInstaller {
    private let expectedBundleIdentifier: String
    private let expectedTeamIdentifier: String
    private let isNewer: (String, String) -> Bool

    init(
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        isNewer: @escaping (String, String) -> Bool
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.isNewer = isNewer
    }

    func verifyChecksum(zipURL: URL, listing: String, assetName: String) throws {
        guard let expectedHash = ChecksumListing.lookup(in: listing, assetName: assetName) else {
            throw UpdateInstallError.checksumMissing(assetName)
        }

        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = fileHandle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard actualHash == expectedHash else {
            throw UpdateInstallError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }
    }

    func extractZip(_ zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let updateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtomVoiceUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)

        try validateZipEntries(zipURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", zipURL.path, "-d", updateDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateInstallError.unzipFailed(proc.terminationStatus)
        }

        let contents = try fm.contentsOfDirectory(at: updateDir, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first else {
            throw UpdateInstallError.appNotFound
        }
        return newApp
    }

    private func validateZipEntries(_ zipURL: URL) throws {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", zipURL.path]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateInstallError.zipListingFailed(proc.terminationStatus)
        }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let listing = String(data: output, encoding: .utf8) else {
            throw UpdateInstallError.invalidZipEntry("<invalid utf8>")
        }

        for entry in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(entry)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.hasPrefix("/") || components.contains("..") || path.contains("\0") {
                throw UpdateInstallError.invalidZipEntry(path)
            }
        }
    }

    func validateDownloadedApp(_ appURL: URL, currentVersion: String, expectedVersion: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw UpdateInstallError.invalidBundle("Cannot read Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier else {
            throw UpdateInstallError.invalidBundle("Unexpected bundle identifier")
        }

        guard let downloadedVersion = info["CFBundleShortVersionString"] as? String,
              isNewer(downloadedVersion, currentVersion) || downloadedVersion == expectedVersion else {
            throw UpdateInstallError.invalidBundle("Downloaded app version is not newer")
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw UpdateInstallError.signatureInvalid(Self.securityErrorDescription(createStatus))
        }

        let requirementText = """
        anchor apple generic and identifier "\(expectedBundleIdentifier)" and certificate leaf[subject.OU] = "\(expectedTeamIdentifier)"
        """
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw UpdateInstallError.signatureInvalid(Self.securityErrorDescription(requirementStatus))
        }

        var validationError: Unmanaged<CFError>?
        let validateStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement,
            &validationError
        )
        if validateStatus != errSecSuccess {
            let detail = validationError?.takeRetainedValue().localizedDescription
            throw UpdateInstallError.signatureInvalid(Self.securityErrorDescription(validateStatus, detail: detail))
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let dict = signingInfo as? [String: Any],
              dict[kSecCodeInfoIdentifier as String] as? String == expectedBundleIdentifier,
              dict[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamIdentifier else {
            throw UpdateInstallError.signatureInvalid(Self.securityErrorDescription(infoStatus))
        }
    }

    func applyAndRelaunch(newAppURL: URL, currentBundlePath: String) throws {
        let newPath = newAppURL.path
        let tmpDir = newAppURL.deletingLastPathComponent().path
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("atomvoice_update_\(UUID().uuidString).sh")

        let script = """
        #!/bin/bash
        set -euo pipefail
        current_path="$1"
        new_path="$2"
        tmp_dir="$3"
        backup_path="${current_path}.previous"

        sleep 1.5
        rm -rf -- "$backup_path"
        if [ -e "$current_path" ]; then
          mv -- "$current_path" "$backup_path"
        fi
        if ditto -- "$new_path" "$current_path"; then
          open -- "$current_path"
          rm -rf -- "$backup_path"
          rm -rf -- "$tmp_dir"
          rm -f -- "$0"
        else
          rm -rf -- "$current_path"
          if [ -e "$backup_path" ]; then
            mv -- "$backup_path" "$current_path"
          fi
          rm -rf -- "$tmp_dir"
          rm -f -- "$0"
          exit 1
        fi
        """

        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath, currentBundlePath, newPath, tmpDir]
        try proc.run()
    }

    static func securityErrorDescription(_ status: OSStatus, detail: String? = nil) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        if let detail, !detail.isEmpty {
            return "\(message): \(detail)"
        }
        return message
    }
}
