import Foundation

/// 已解析的 release 资产元数据，供下载与校验阶段使用。
/// (Resolved release asset metadata, consumed by download & verification stages.)
struct ReleaseInfo: Equatable {
    let version: String
    let downloadURL: URL
    let assetName: String
    let checksumsURL: URL
    let isPreRelease: Bool
    let isDebugBuild: Bool
    let summary: String?

    init(
        version: String,
        downloadURL: URL,
        assetName: String,
        checksumsURL: URL,
        isPreRelease: Bool,
        isDebugBuild: Bool,
        summary: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.assetName = assetName
        self.checksumsURL = checksumsURL
        self.isPreRelease = isPreRelease
        self.isDebugBuild = isDebugBuild
        self.summary = summary
    }

    /// 展示文案可在发布后编辑，不能参与已验证安装包的复用判断。
    func hasSameInstallArtifact(as other: ReleaseInfo) -> Bool {
        version == other.version
            && downloadURL == other.downloadURL
            && assetName == other.assetName
            && checksumsURL == other.checksumsURL
            && isDebugBuild == other.isDebugBuild
    }
}

/// 抽象出 release 来源（默认是 GitHub Releases），让 UpdateChecker 不直接持有网络细节。
/// (Abstracts where releases come from — default is GitHub Releases — so UpdateChecker
/// doesn't own networking details directly.)
protocol ReleaseSource: AnyObject {
    func fetchLatestRelease(
        includeBeta: Bool,
        preferDebugBuild: Bool,
        completion: @escaping (Result<ReleaseInfo, Error>) -> Void
    )

    /// 下载回调内取得自有文件；调用方持有对象期间文件保持可读。
    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<OwnedUpdateArtifact, Error>) -> Void)

    /// 拉取 SHA256SUMS.txt 全文。
    /// (Fetch SHA256SUMS.txt listing as a string.)
    func fetchChecksumsListing(for release: ReleaseInfo, completion: @escaping (Result<String, Error>) -> Void)
}

/// 默认实现：从指定 owner/repo 的 GitHub Releases 拉取。
/// (Default implementation: pulls from the configured owner/repo on GitHub Releases.)
final class GitHubReleaseSource: ReleaseSource {
    private static let summaryCharacterLimit = 240
    private static let summaryScalarLimit = 1_024
    private let owner: String
    private let repo: String
    private let session: URLSession

    init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    /// 只读取 release body 中严格的一行摘要标记；中文环境缺失时回退英文。
    static func releaseSummary(
        from body: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        let preferred = preferredLanguages.first?.lowercased() ?? "en"
        let languageKeys = preferred.hasPrefix("zh") ? ["zh", "en"] : ["en"]
        for languageKey in languageKeys {
            if let summary = releaseSummary(from: body, languageKey: languageKey) {
                return summary
            }
        }
        return nil
    }

    private static func releaseSummary(from body: String, languageKey: String) -> String? {
        let prefix = "<!-- atomvoice-summary-\(languageKey):"
        var didMatchMarker = false
        var matchedSummary: String?
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix("-->") else { continue }
            // 同一语言出现多个标记时拒绝展示，避免发布正文产生歧义。
            guard !didMatchMarker else { return nil }
            didMatchMarker = true
            let content = line.dropFirst(prefix.count).dropLast(3)
            guard !content.contains("<!--"), !content.contains("-->") else { return nil }
            matchedSummary = sanitizedSummary(content)
        }
        return matchedSummary
    }

    private static func sanitizedSummary(_ raw: Substring) -> String? {
        // 先限制 scalar 数，避免单个组合字符携带大量标记拖慢弹窗渲染。
        var filtered = ""
        filtered.reserveCapacity(summaryCharacterLimit)
        for scalar in raw.unicodeScalars.prefix(summaryScalarLimit) where !isUnsafeSummaryScalar(scalar) {
            filtered.unicodeScalars.append(scalar)
        }
        let cleaned = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > summaryCharacterLimit {
            return String(cleaned.prefix(summaryCharacterLimit - 1)) + "…"
        }
        return cleaned
    }

    private static func isUnsafeSummaryScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F...0x009F,
             0x061C, 0x200B...0x200C, 0x200E...0x200F,
             0x2028...0x202E, 0x2060...0x206F, 0xFEFF:
            return true
        default:
            return false
        }
    }

    func fetchLatestRelease(
        includeBeta: Bool,
        preferDebugBuild: Bool,
        completion: @escaping (Result<ReleaseInfo, Error>) -> Void
    ) {
        // includeBeta 时拉取列表取第一条（含 pre-release），否则只取正式最新版。
        // (When includeBeta is true, fetch the list and take the first entry including pre-release; otherwise fetch only the latest stable release.)
        let urlStr = includeBeta
            ? "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=1"
            : "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(URLError(.badServerResponse))); return }
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data)
                let json: [String: Any]?
                if let arr = jsonObject as? [[String: Any]] {
                    json = arr.first
                } else {
                    json = jsonObject as? [String: Any]
                }
                guard let json,
                      let tagName = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]]
                else { completion(.failure(URLError(.cannotParseResponse))); return }

                let isPreRelease = json["prerelease"] as? Bool ?? false
                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let summary = (json["body"] as? String).flatMap { Self.releaseSummary(from: $0) }

                guard let release = Self.match(
                    assets: assets,
                    version: version,
                    isPreRelease: isPreRelease,
                    preferDebugBuild: preferDebugBuild,
                    summary: summary
                ) else {
                    completion(.failure(URLError(.fileDoesNotExist)))
                    return
                }
                completion(.success(release))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<OwnedUpdateArtifact, Error>) -> Void) {
        session.downloadTask(with: release.downloadURL) { tmpURL, _, error in
            if let error { completion(.failure(error)); return }
            guard let tmpURL else { completion(.failure(URLError(.badServerResponse))); return }
            do {
                completion(.success(try OwnedUpdateArtifact.acquireDownload(tmpURL)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func fetchChecksumsListing(for release: ReleaseInfo, completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: release.checksumsURL, timeoutInterval: 15)
        req.setValue("text/plain", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data, let listing = String(data: data, encoding: .utf8) else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(listing))
        }.resume()
    }

    /// 按当前更新通道匹配资产。
    /// (Match asset for the current update channel.)
    static func match(
        assets: [[String: Any]],
        version: String,
        isPreRelease: Bool,
        preferDebugBuild: Bool,
        summary: String? = nil
    ) -> ReleaseInfo? {
        guard let checksumsAsset = assets.first(where: { ($0["name"] as? String) == "SHA256SUMS.txt" }),
              let checksumsURLStr = checksumsAsset["browser_download_url"] as? String,
              let checksumsURL = URL(string: checksumsURLStr) else {
            return nil
        }

        let preferred: [String]
        if preferDebugBuild {
            preferred = ["Debug-Universal", "DebugUniversal", "Debug"]
        } else {
            #if arch(arm64)
            preferred = ["AppleSilicon", "Universal"]
            #else
            preferred = ["Intel", "Universal"]
            #endif
        }

        for suffix in preferred {
            if let asset = assets.first(where: {
                guard let name = $0["name"] as? String else { return false }
                guard name.contains(suffix), name.hasSuffix(".zip") else { return false }
                let isDebugAsset = name.localizedCaseInsensitiveContains("debug")
                return preferDebugBuild ? isDebugAsset : !isDebugAsset
            }),
               let assetName = asset["name"] as? String,
               let dlStr = asset["browser_download_url"] as? String,
               let dlURL = URL(string: dlStr) {
                return ReleaseInfo(
                    version: version,
                    downloadURL: dlURL,
                    assetName: assetName,
                    checksumsURL: checksumsURL,
                    isPreRelease: isPreRelease,
                    isDebugBuild: preferDebugBuild,
                    summary: summary
                )
            }
        }
        return nil
    }
}

/// SHA256SUMS.txt 解析；提供给 UpdateChecker 与 UpdateInstaller 共用。
/// (SHA256SUMS.txt parsing; shared by UpdateChecker and UpdateInstaller.)
enum ChecksumListing {
    /// 按资产文件名查 hash；`shasum -a 256` 输出每行为 "<sha256>  <filename>"，名字可前缀 `*`（二进制模式）。
    /// (Lookup hash by asset name; `shasum -a 256` outputs "<sha256>  <filename>" per line, filename may be prefixed with `*` in binary mode.)
    static func lookup(in listing: String, assetName: String) -> String? {
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == assetName {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }
}
