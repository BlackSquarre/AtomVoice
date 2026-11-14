import CryptoKit
import Foundation
import SherpaOnnxShim

/// 官方发布资产与已确认兼容版本；下载目标始终从 latest 元数据获取。
struct SherpaRuntimeRelease {
    let version: String
    let size: Int64
    let sha256: String

    static let knownCompatible: [SherpaRuntimeRelease] = [
        .init(version: "v2.0.1", size: 18_104_974, sha256: "242b0593a033456e9344a76a11713d1c55da794d0e37eabf6acabaf7beeb2b36"),
        .init(version: "v2.0.0", size: 18_056_595, sha256: "30be0a78492496389f80b7ca2356ac0de71653280d5a9b536e5714afd61177c4"),
        .init(version: "v1.13.8", size: 17_827_519, sha256: "bdcc7c266d355697584dd4efb9dc766e45e18e87cec1fc553002a32cfcfab9a7"),
    ]
    static func requiresVersionRestriction(on os: OperatingSystemVersion) -> Bool {
        os.majorVersion < 15 || (os.majorVersion == 15 && os.minorVersion < 5)
    }

    static func compatibilityNotice(on os: OperatingSystemVersion) -> String? {
        guard requiresVersionRestriction(on: os) else { return nil }
        let versions = knownCompatible.map { "• " + $0.version }.joined(separator: "\n")
        return loc("sherpa.runtime.compatibilityNotice", versions)
    }

    static func fromLatestResponse(_ data: Data) throws -> SherpaRuntimeRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["tag_name"] as? String,
              version.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              json["prerelease"] as? Bool == false, json["draft"] as? Bool == false,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == SherpaModelDownloader.runtimeArchiveRootName(for: version) + ".tar.bz2" }),
              let size = asset["size"] as? Int64, size > 0,
              let digest = asset["digest"] as? String,
              digest.range(of: "^sha256:[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw SherpaRuntimeInstallError.releaseMetadata
        }
        return .init(version: version, size: size, sha256: String(digest.dropFirst(7)).lowercased())
    }

    func verifyArchive(_ archive: URL) throws {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == self.size else { throw SherpaRuntimeInstallError.integrity }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else { throw SherpaRuntimeInstallError.integrity }
    }
}

/// Swift 查询与 C shim 加载共用同一个文件名解析器；解析不会 dlopen 或加载模型。
struct SherpaRuntimeLayout {
    static let sherpaLibrary = "libsherpa-onnx-c-api.dylib"
    static let preferredOnnxLibrary = "libonnxruntime.dylib"
    let sherpa: URL
    let onnx: URL

    static func resolve(in directory: URL) -> SherpaRuntimeLayout? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let found = directory.path.withCString { path in
            AtomVoiceSherpaResolveOnnxRuntime(path, &buffer, 4096)
        }
        guard found != 0 else { return nil }
        let layout = Self(sherpa: directory.appendingPathComponent(sherpaLibrary),
                          onnx: URL(fileURLWithPath: String(cString: buffer)))
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard [layout.sherpa, layout.onnx].allSatisfy({
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) && SherpaResources.isUsableFile($0)
        }) else { return nil }
        return layout
    }

    func isCompatible(on os: OperatingSystemVersion) -> Bool {
        [sherpa, onnx].allSatisfy { SherpaRuntimeBinary.supports($0, on: os) }
    }
}

enum SherpaRuntimeInstallError: Error, LocalizedError, CustomStringConvertible {
    case integrity
    case missingLibraries
    case extraction(String)
    case unsafeArchive
    case releaseMetadata
    case incompatibleSystem

    var errorDescription: String? {
        switch self {
        case .integrity: return loc("sherpa.runtime.error.integrity")
        case .missingLibraries: return loc("sherpa.runtime.error.missingLibraries")
        case .extraction: return loc("sherpa.runtime.error.extraction")
        case .unsafeArchive: return loc("sherpa.runtime.error.unsafeArchive")
        case .releaseMetadata: return loc("sherpa.runtime.error.releaseMetadata")
        case .incompatibleSystem: return loc("sherpa.runtime.error.incompatibleSystem")
        }
    }
    var description: String {
        if case .extraction(let detail) = self { return "tar: \(detail)" }
        return errorDescription ?? "Sherpa installation failed"
    }
}
