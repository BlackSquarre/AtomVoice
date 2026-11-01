import Foundation

enum SherpaDownloadSources {
    // MARK: - 镜像站逻辑（Mirror site logic）

    /// 可用的 GitHub 镜像前缀，按优先级排序（Available GitHub mirror prefixes, in priority order）
    static let mirrorPrefixes: [String] = [
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://gh.llkk.cc/",
    ]

    private static let mirrorCacheKey = AppSettings.Keys.sherpaMirrorCached

    static var prefersMirror: Bool {
        AppSettings.backend.bool(forKey: mirrorCacheKey, default: false)
    }

    static func probeMirrorAsync() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(string: "https://github.com")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: request) { _, response, error in
                let reachable = error == nil &&
                    (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } == true
                AppSettings.backend.set(!reachable, forKey: mirrorCacheKey)
            }
            task.resume()
        }
    }

    static func resetMirrorCache() {
        AppSettings.backend.set(nil, forKey: mirrorCacheKey)
    }

    static func candidateURLs(for githubURL: URL) -> [URL] {
        let raw = githubURL.absoluteString
        let mirrored: [URL] = mirrorPrefixes.compactMap { URL(string: $0 + raw) }
        if prefersMirror {
            return mirrored + [githubURL]
        } else {
            return [githubURL] + mirrored
        }
    }

}
