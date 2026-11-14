import Foundation

/// 下载 owner 只负责一次尝试、候选重试和 observer；落盘由安装边界承担。
final class SherpaModelDownloader: NSObject, URLSessionDownloadDelegate {
    enum StartResult: Equatable { case started, alreadyDownloading }
    static let shared = SherpaModelDownloader()
    typealias ProgressHandler = (Int, Int, Double, String) -> Void
    typealias CompleteHandler = (Bool, String?) -> Void
    private struct Observer { let progress: ProgressHandler?; let complete: CompleteHandler? }
    private var observers: [UUID: Observer] = [:]
    private let installation: SherpaDownloadInstallation
    private let fetchRelease: (@escaping (Result<SherpaRuntimeRelease, Error>) -> Void) -> Void
    private let configuration: () -> URLSessionConfiguration
    private var attempt: SherpaInstallAttempt?
    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var items: [SherpaDownloadItem] = []
    private var itemIndex = 0
    private var candidateIndex = 0
    private var candidateRetry = 0
    private static let maxRetriesPerCandidate = 1
    private var targetPreset: SherpaModelPreset?
    private var targetVersion = ""
    private var runtimeOnly = false
    private(set) var isDownloading = false

    init(paths: SherpaResourcePaths = .current,
         fetchRelease: @escaping (@escaping (Result<SherpaRuntimeRelease, Error>) -> Void) -> Void = SherpaModelDownloader.fetchLatestRuntimeRelease,
         configuration: @escaping () -> URLSessionConfiguration = { .default }) {
        installation = .init(paths: paths)
        self.fetchRelease = fetchRelease
        self.configuration = configuration
        super.init()
    }

    static func runtimeArchiveRootName(for version: String) -> String {
        return "sherpa-onnx-\(version)-osx-universal2-shared-no-tts-lib"
    }

    static func runtimeArchiveGitHubURL(for version: String) -> URL {
        return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/\(version)/\(runtimeArchiveRootName(for: version)).tar.bz2")!
    }

    /// 查询最新正式发布；版本、大小和摘要绑定到同一份响应，不回退到固定旧版。
    static func fetchLatestRuntimeRelease(completion: @escaping (Result<SherpaRuntimeRelease, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AtomVoice-SherpaDownloader", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                completion(.failure(SherpaRuntimeInstallError.releaseMetadata)); return
            }
            completion(Result { try SherpaRuntimeRelease.fromLatestResponse(data) })
        }.resume()
    }


    @discardableResult
    func addObserver(progress: ProgressHandler? = nil, complete: CompleteHandler? = nil) -> UUID {
        let id = UUID()
        observers[id] = .init(progress: progress, complete: complete)
        return id
    }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func notifyProgress(_ overall: Double, _ message: String, attempt: SherpaInstallAttempt) {
        guard self.attempt === attempt, attempt.isActive else { return }
        let snapshot = Array(observers.values)
        snapshot.forEach { $0.progress?(itemIndex + 1, items.count, overall, message) }
    }

    private func finish(_ success: Bool, _ message: String?, attempt: SherpaInstallAttempt) {
        guard self.attempt === attempt else { return }
        attempt.cancel()
        self.attempt = nil
        isDownloading = false
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        targetPreset = nil
        let snapshot = Array(observers.values)
        observers.removeAll()
        // 先结束旧任务再回调；新订阅不会被旧完成回调清空。
        snapshot.forEach { $0.complete?(success, message) }
    }

    static var runtimeVersionFileURL: URL { SherpaResourcePaths.current.version }
    static func getLocalRuntimeVersion() -> String {
        if let version = try? String(contentsOf: runtimeVersionFileURL, encoding: .utf8) {
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return runtimeRequiredFiles().allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } ? "v1.13.0" : "n/a"
    }
    static func runtimeRequiredFiles() -> [(name: String, url: URL)] {
        let directory = SherpaResourcePaths.current.runtime
        if let layout = SherpaRuntimeLayout.resolve(in: directory) {
            return [layout.sherpa, layout.onnx].map { ($0.lastPathComponent, $0) }
        }
        return SherpaResourcePaths.runtimeLibraries.map { ($0, directory.appendingPathComponent($0)) }
    }
    static func punctuationRequiredFile() -> URL { SherpaResourcePaths.current.punctuation.appendingPathComponent("model.int8.onnx") }
    static func allModelsReady(for preset: SherpaModelPreset = .current) -> Bool {
        SherpaResources().status(for: preset).allReady
    }
    /// 兼容既有调用方；新调用明确使用 ensureReady，以免把修复当纯查询。
    static func isReady(for preset: SherpaModelPreset = .current) -> Bool { ensureReady(for: preset) }
    static func ensureReady(for preset: SherpaModelPreset = .current) -> Bool {
        _ = SherpaResources().ensureRecognitionReady(for: preset)
        return allModelsReady(for: preset)
    }
    static func ensureRecognitionReady(for preset: SherpaModelPreset = .current) -> Bool {
        SherpaResources().ensureRecognitionReady(for: preset)
    }
    @discardableResult
    static func repairExtractedFilesIfNeeded(for preset: SherpaModelPreset = .current) -> Bool {
        do { try SherpaResources().repairRuntimeIfNeeded() }
        catch { DebugLog.error("[SherpaOnnx] Failed to repair runtime library path: \(error)") }
        return allModelsReady(for: preset)
    }
    static func printMissingRequiredFiles(for preset: SherpaModelPreset = .current) {
        let status = SherpaResources().status(for: preset)
        DebugLog.error("[SherpaOnnx] Resource status runtime=\(status.runtimeReady) model=\(status.modelReady) punctuation=\(status.punctuationReady)")
    }

    @discardableResult
    func startDownload(forceUpdateRuntime: Bool = false, runtimeOnly: Bool = false, replaceModel: Bool = false) -> StartResult {
        startDownload(preset: .current, forceUpdateRuntime: forceUpdateRuntime, runtimeOnly: runtimeOnly, replaceModel: replaceModel)
    }
    @discardableResult
    func startDownload(preset: SherpaModelPreset, forceUpdateRuntime: Bool = false,
                       runtimeOnly: Bool = false, replaceModel: Bool = false,
                       runtimeRelease: SherpaRuntimeRelease? = nil) -> StartResult {
        guard !isDownloading else { return .alreadyDownloading }
        let attempt = SherpaInstallAttempt()
        self.attempt = attempt
        isDownloading = true
        targetPreset = preset
        self.runtimeOnly = runtimeOnly
        let begin: (Result<SherpaRuntimeRelease?, Error>) -> Void = { [weak self, attempt] result in
            DispatchQueue.main.async {
                guard let self, self.attempt === attempt, attempt.isActive else { return }
                guard case .success(let release) = result else {
                    if case .failure(let error) = result {
                        DebugLog.error("[SherpaDownload] Could not query latest runtime release: \(error)")
                    }
                    self.finish(false, loc("sherpa.runtime.error.releaseMetadata"), attempt: attempt)
                    return
                }
                let version = release?.version ?? (try? String(contentsOf: self.installation.paths.version, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "n/a"
                self.targetVersion = version
                self.items = self.installation.plan(preset: preset, version: version, forceRuntime: forceUpdateRuntime,
                    runtimeOnly: runtimeOnly, replaceModel: replaceModel, runtimeRelease: release)
                self.itemIndex = 0
                self.candidateIndex = 0
                self.candidateRetry = 0
                let config = self.configuration()
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 600
                self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
                self.downloadCurrent(attempt: attempt)
            }
        }
        // 设置页已确认的最新发布沿用同一元数据快照，避免确认后又查询到另一版本。
        if let runtimeRelease { begin(.success(runtimeRelease)) }
        else if !forceUpdateRuntime && SherpaResources(paths: installation.paths).runtimeReady {
            // 只补模型/标点时沿用可用运行库，避免无关的 latest API 故障阻断模型下载。
            begin(.success(nil))
        } else { fetchRelease { begin($0.map { Optional($0) }) } }
        return .started
    }
    func cancel() {
        guard let attempt else { return }
        attempt.cancel()
        finish(false, "Cancelled", attempt: attempt)
    }

    private func overall(_ itemProgress: Double) -> Double {
        items.isEmpty ? 0 : (Double(itemIndex) + itemProgress) / Double(items.count)
    }
    private func progressMessage(written: Int64, expected: Int64) -> String {
        let key = items[itemIndex].kind == .runtime ? "sherpa.runtime.downloading.progressWithSize" : "sherpa.downloading.progressWithSize"
        let writtenMB = expected > 0 ? String(format: "%.1f", Double(written) / 1_048_576) : "--"
        let expectedMB = expected > 0 ? String(format: "%.1f", Double(expected) / 1_048_576) : "--"
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        return loc(key, itemIndex + 1, items.count, Int(overall(fraction) * 100), writtenMB, expectedMB)
    }
    private func downloadCurrent(attempt: SherpaInstallAttempt) {
        guard self.attempt === attempt, attempt.isActive, let preset = targetPreset else { return }
        guard itemIndex < items.count else {
            let status = SherpaResources(paths: installation.paths).status(for: preset)
            let ready = runtimeOnly ? status.runtimeReady : status.allReady
            finish(ready, ready ? nil : "Extracted files not found", attempt: attempt)
            return
        }
        let item = items[itemIndex]
        guard candidateIndex < item.urlCandidates.count else {
            finish(false, loc("sherpa.download.error.allMirrorsFailed", item.name), attempt: attempt)
            return
        }
        notifyProgress(overall(0), progressMessage(written: 0, expected: 0), attempt: attempt)
        // progress observer 可以取消本轮，创建 task 前再次确认归属。
        guard self.attempt === attempt, attempt.isActive else { return }
        currentTask = session?.downloadTask(with: item.urlCandidates[candidateIndex])
        currentTask?.resume()
    }
    private func failCurrentCandidate(attempt: SherpaInstallAttempt) {
        guard self.attempt === attempt, attempt.isActive else { return }
        currentTask = nil
        if candidateRetry < Self.maxRetriesPerCandidate { candidateRetry += 1 }
        else { candidateIndex += 1; candidateRetry = 0 }
        downloadCurrent(attempt: attempt)
    }
    private func owns(_ session: URLSession, _ task: URLSessionTask) -> SherpaInstallAttempt? {
        guard self.session === session, currentTask === task, let attempt, attempt.isActive,
              itemIndex < items.count else { return nil }
        return attempt
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let attempt = owns(session, downloadTask), let preset = targetPreset else { return }
        let item = items[itemIndex]
        let version = targetVersion
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DebugLog.error("[SherpaDownload] item=\(item.name) HTTP status=\(http.statusCode) candidate=\(candidateIndex) retry=\(candidateRetry)")
            failCurrentCandidate(attempt: attempt)
            return
        }
        // 回调返回前取得文件所有权；每轮/每项使用独立暂存路径。
        let archive = attempt.workingDirectory.appendingPathComponent(UUID().uuidString + "-" + item.archiveName)
        do {
            try FileManager.default.createDirectory(at: attempt.workingDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: archive)
        } catch {
            finish(false, loc("sherpa.download.error.moveFailed", error.localizedDescription), attempt: attempt)
            return
        }
        currentTask = nil
        let key = item.kind == .runtime ? "sherpa.runtime.extracting" : "sherpa.extracting"
        notifyProgress(overall(1), loc(key, itemIndex + 1, items.count), attempt: attempt)
        let installation = self.installation
        DispatchQueue.global(qos: .utility).async { [weak self, attempt] in
            defer { try? FileManager.default.removeItem(at: archive) }
            guard attempt.isActive else { return }
            let result = Result { try installation.install(archive: archive, item: item, preset: preset, version: version, attempt: attempt) }
            DispatchQueue.main.async {
                guard let self, self.attempt === attempt, attempt.isActive else { return }
                switch result {
                case .success(true):
                    self.itemIndex += 1
                    self.candidateIndex = 0
                    self.candidateRetry = 0
                    self.downloadCurrent(attempt: attempt)
                case .success(false): break
                case .failure(let error):
                    DebugLog.error("[SherpaDownload] item=\(item.name) version=\(version) installation failed: \(error)")
                    let message = (error as? SherpaRuntimeInstallError)?.errorDescription
                        ?? loc("sherpa.download.error.installFailed", item.name)
                    self.finish(false, message, attempt: attempt)
                }
            }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let attempt = owns(session, downloadTask) else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        notifyProgress(overall(fraction), progressMessage(written: totalBytesWritten, expected: totalBytesExpectedToWrite), attempt: attempt)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let attempt = owns(session, task), let error = error as NSError?, error.code != NSURLErrorCancelled else { return }
        failCurrentCandidate(attempt: attempt)
    }
}
