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

    /// 下载资产到临时文件，返回该临时文件 URL。
    /// (Download the asset zip to a temp file; return the temp URL.)
    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<URL, Error>) -> Void)

    /// 拉取 SHA256SUMS.txt 全文。
    /// (Fetch SHA256SUMS.txt listing as a string.)
    func fetchChecksumsListing(for release: ReleaseInfo, completion: @escaping (Result<String, Error>) -> Void)
}

/// 默认实现：从指定 owner/repo 的 GitHub Releases 拉取。
/// (Default implementation: pulls from the configured owner/repo on GitHub Releases.)
final class GitHubReleaseSource: ReleaseSource {
    private let owner: String
    private let repo: String
    private let session: URLSession

    init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
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

                guard let release = Self.match(
                    assets: assets,
                    version: version,
                    isPreRelease: isPreRelease,
                    preferDebugBuild: preferDebugBuild
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

    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<URL, Error>) -> Void) {
        session.downloadTask(with: release.downloadURL) { tmpURL, _, error in
            if let error { completion(.failure(error)); return }
            guard let tmpURL else { completion(.failure(URLError(.badServerResponse))); return }
            completion(.success(tmpURL))
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
        preferDebugBuild: Bool
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
                    isDebugBuild: preferDebugBuild
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
