import Foundation

/// Sherpa 模型下载管理器（Sherpa Model Download Manager）
/// 三个组件：Runtime dylib、ASR 模型、标点模型（Three components: Runtime dylib, ASR model, punctuation model）
/// 下载 → 解压 → 清理临时文件（Download → Extract → Clean up temp files）
final class SherpaModelDownloader: NSObject, URLSessionDownloadDelegate {
    private static let runtimeArchiveRootName = "sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib"
    private static let runtimeArchiveGitHubURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib.tar.bz2")!
    private static let punctArchiveGitHubURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2")!
    private static let punctArchiveName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2"
    private static let runtimeArchiveName = "sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib.tar.bz2"

    private static let requiredRuntimeLibs = [
        "libsherpa-onnx-c-api.dylib",
        "libonnxruntime.1.24.4.dylib",
    ]

    struct DownloadItem {
        let name: String
        let urlCandidates: [URL]   // 直链 + 所有镜像，按优先级排序（Direct + mirrors, in priority order）
        let extractDir: URL        // 解压目标目录（父目录）（Extract target directory (parent)）
        let archiveName: String
    }

    static let shared = SherpaModelDownloader()

    /// 下载进度回调；多订阅，互不覆盖（Multi-subscriber download progress callback）
    /// - Parameters:
    ///   - currentItem: 当前第几个（1-based）（Current item number (1-based)）
    ///   - totalItems: 总数（Total count）
    ///   - overallProgress: 总进度 0.0~1.0（Overall progress 0.0~1.0）
    ///   - message: 状态文字（Status message）
    typealias ProgressHandler = (_ currentItem: Int, _ totalItems: Int, _ overallProgress: Double, _ message: String) -> Void
    typealias CompleteHandler = (_ success: Bool, _ error: String?) -> Void

    private struct Observer {
        let progress: ProgressHandler?
        let complete: CompleteHandler?
    }

    private var observers: [UUID: Observer] = [:]

    /// 注册下载进度/完成订阅，返回的 token 用于取消（Register progress/complete subscription, returned token used to cancel）
    @discardableResult
    func addObserver(progress: ProgressHandler? = nil, complete: CompleteHandler? = nil) -> UUID {
        let token = UUID()
        observers[token] = Observer(progress: progress, complete: complete)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notifyProgress(_ current: Int, _ total: Int, _ overall: Double, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.observers.values.forEach { $0.progress?(current, total, overall, message) }
        }
    }

    private func notifyComplete(_ success: Bool, _ message: String?) {
        DispatchQueue.main.async { [weak self] in
            // 复制订阅者快照避免遍历期间被修改（Snapshot observers to avoid mutation during iteration）
            let snapshot = self?.observers.values.map { $0 } ?? []
            // 完成后清空所有订阅者，避免下次下载又触发旧 closure（Clear all observers after completion to avoid stale closures next time）
            self?.observers.removeAll()
            snapshot.forEach { $0.complete?(success, message) }
        }
    }

    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var itemsToDownload: [DownloadItem] = []
    private var currentItemIndex = 0
    private var currentCandidateIndex = 0
    private var currentCandidateRetry = 0
    private static let maxRetriesPerCandidate = 1   // 每个镜像额外重试次数（Extra retries per mirror）
    private var totalItems = 0
    private(set) var isDownloading = false
    /// 当前下载会话锁定的目标 preset，用于完成时正确校验（Target preset locked for this session, used for correct readiness check on completion）
    private var targetPreset: SherpaModelPreset?

    /// 计算总体进度：已完成 item 各算 1.0，当前 item 取实时（Compute overall progress: completed items count as 1.0, current item uses live progress）
    private func computeOverallProgress(itemProgress: Double) -> Double {
        guard totalItems > 0 else { return 0 }
        return (Double(currentItemIndex) + itemProgress) / Double(totalItems)
    }

    /// 简单的运行库文件清单（Simple runtime file list）
    /// ASR 模型完整性走 ModelManifest，标点模型只看 model.int8.onnx 是否存在
    /// (ASR model completeness goes via ModelManifest; punct model just checks model.int8.onnx)
    static func runtimeRequiredFiles() -> [(name: String, url: URL)] {
        let rt = SherpaOnnxRecognizerController.runtimeLibDirectory
        return [
            ("libsherpa-onnx-c-api.dylib", rt.appendingPathComponent("libsherpa-onnx-c-api.dylib")),
            ("libonnxruntime.1.24.4.dylib", rt.appendingPathComponent("libonnxruntime.1.24.4.dylib")),
        ]
    }

    static func punctuationRequiredFile() -> URL {
        SherpaOnnxRecognizerController.punctuationModelDirectory.appendingPathComponent("model.int8.onnx")
    }

    /// 是否所有模型都已存在（按指定 preset）（Whether all required files exist for given preset）
    static func allModelsReady(for preset: SherpaModelPreset = SherpaModelPreset.current) -> Bool {
        let runtimeOK = runtimeRequiredFiles().allSatisfy { SherpaModelPreset.isUsableFile($0.url) }
        let asrOK = preset.resolveManifest() != nil
        let punctOK = SherpaModelPreset.isUsableFile(punctuationRequiredFile())
        return runtimeOK && asrOK && punctOK
    }

    /// 综合检查：先看文件是否齐，再尝试一次轻量自愈（从解压根目录把运行库 copy 到 runtime/lib）
    /// (Composite check: first verify all files, then attempt one lightweight self-heal copying libs from extracted root to runtime/lib)
    static func isReady(for preset: SherpaModelPreset = SherpaModelPreset.current) -> Bool {
        if allModelsReady(for: preset) { return true }
        return repairExtractedFilesIfNeeded(for: preset)
    }

    @discardableResult
    static func repairExtractedFilesIfNeeded(for preset: SherpaModelPreset = SherpaModelPreset.current) -> Bool {
        let sourceLibDirectory = SherpaOnnxRecognizerController.supportDirectory
            .appendingPathComponent(runtimeArchiveRootName, isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
        let targetLibDirectory = SherpaOnnxRecognizerController.runtimeLibDirectory

        do {
            try FileManager.default.createDirectory(at: targetLibDirectory, withIntermediateDirectories: true)
            for libName in requiredRuntimeLibs {
                let source = sourceLibDirectory.appendingPathComponent(libName)
                let target = targetLibDirectory.appendingPathComponent(libName)
                guard SherpaModelPreset.isUsableFile(source), !SherpaModelPreset.isUsableFile(target) else { continue }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                DebugLog.info("[SherpaOnnx] 已修复运行库路径: \(target.path)")
            }
        } catch {
            DebugLog.error("[SherpaOnnx] 修复运行库路径失败: \(error)")
            return false
        }

        return allModelsReady(for: preset)
    }

    static func printMissingRequiredFiles(for preset: SherpaModelPreset = SherpaModelPreset.current) {
        var problems: [String] = []
        for f in runtimeRequiredFiles() where !SherpaModelPreset.isUsableFile(f.url) {
            problems.append("运行库 \(f.name): \(f.url.path)")
        }
        if preset.resolveManifest() == nil {
            problems.append("ASR 模型目录无法解析: \(preset.modelDirectory.path)")
        }
        let punct = punctuationRequiredFile()
        if !SherpaModelPreset.isUsableFile(punct) {
            problems.append("标点模型: \(punct.path)")
        }
        if problems.isEmpty {
            DebugLog.info("[SherpaOnnx] 必需文件都存在，但模型仍无法加载，可能是文件损坏或版本不兼容")
            return
        }
        DebugLog.error("[SherpaOnnx] 必需文件缺失或损坏：")
        for line in problems { DebugLog.error("[SherpaOnnx] - \(line)") }
    }

    /// 开始下载所有缺失的模型（Start downloading all missing models）
    func startDownload() {
        startDownload(preset: SherpaModelPreset.current)
    }

    /// 开始下载指定预设模型（Start downloading specified preset model）
    func startDownload(preset: SherpaModelPreset) {
        guard !isDownloading else { return }
        isDownloading = true
        targetPreset = preset

        // 创建目录（Create directories）
        try? SherpaOnnxRecognizerController.createSupportDirectories()

        // 构建下载列表：运行库 + 指定模型 + 标点模型
        let runtimeItem = DownloadItem(
            name: "runtime",
            urlCandidates: SherpaModelPreset.candidateURLs(for: Self.runtimeArchiveGitHubURL),
            extractDir: SherpaOnnxRecognizerController.supportDirectory,
            archiveName: Self.runtimeArchiveName
        )

        // 导入预设没有 archiveURL/archiveName；上层不应把它送进 startDownload
        // (Imported presets have no archive; callers shouldn't pass them to startDownload)
        let asrItem: DownloadItem? = {
            guard let archiveName = preset.archiveName, !preset.downloadURLs.isEmpty else { return nil }
            return DownloadItem(
                name: "asr",
                urlCandidates: preset.downloadURLs,
                extractDir: SherpaOnnxRecognizerController.modelsDirectory,
                archiveName: archiveName
            )
        }()

        let punctItem = DownloadItem(
            name: "punct",
            urlCandidates: SherpaModelPreset.candidateURLs(for: Self.punctArchiveGitHubURL),
            extractDir: SherpaOnnxRecognizerController.modelsDirectory,
            archiveName: Self.punctArchiveName
        )

        // 检查哪些需要下载
        itemsToDownload = []
        let runtimeMissing = Self.requiredRuntimeLibs.contains {
            !SherpaModelPreset.isUsableFile(SherpaOnnxRecognizerController.runtimeLibDirectory.appendingPathComponent($0))
        }
        if runtimeMissing {
            itemsToDownload.append(runtimeItem)
        }
        if !preset.isDownloaded, let asrItem {
            itemsToDownload.append(asrItem)
        }
        if !SherpaModelPreset.isUsableFile(SherpaOnnxRecognizerController.punctuationModelDirectory.appendingPathComponent("model.int8.onnx")) {
            itemsToDownload.append(punctItem)
        }

        guard !itemsToDownload.isEmpty else {
            isDownloading = false
            let success = Self.isReady(for: preset)
            if !success { Self.printMissingRequiredFiles(for: preset) }
            notifyComplete(success, success ? nil : "Extracted files not found")
            return
        }

        currentItemIndex = 0
        currentCandidateIndex = 0
        currentCandidateRetry = 0
        totalItems = itemsToDownload.count

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        downloadCurrent()
    }

    /// 取消下载（Cancel download）
    func cancel() {
        currentTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        isDownloading = false
        targetPreset = nil
    }

    // MARK: - Private

    private func advanceToNextItem() {
        currentItemIndex += 1
        currentCandidateIndex = 0
        currentCandidateRetry = 0
        downloadCurrent()
    }

    /// 当前候选失败：先重试 N 次，再切下一个镜像（Current candidate failed: retry N times, then move to next mirror）
    private func failCurrentCandidate() {
        if currentCandidateRetry < Self.maxRetriesPerCandidate {
            currentCandidateRetry += 1
            DebugLog.info("[下载] 第 \(self.currentCandidateRetry) 次重试当前镜像")
        } else {
            currentCandidateIndex += 1
            currentCandidateRetry = 0
        }
        downloadCurrent()
    }

    private func downloadCurrent() {
        guard currentItemIndex < itemsToDownload.count else {
            // 全部完成（All done）
            isDownloading = false
            session?.finishTasksAndInvalidate()
            session = nil

            // 用本次下载锁定的 preset 校验，避免用户中途改了 sherpaModelPresetID 导致校验错位
            // (Verify against the preset locked for this session, not whatever sherpaModelPresetID is now)
            let preset = targetPreset ?? SherpaModelPreset.current
            targetPreset = nil
            let success = Self.isReady(for: preset)
            if success {
                DebugLog.info("[下载] 所有模型验证通过")
            } else {
                Self.printMissingRequiredFiles(for: preset)
            }
            notifyComplete(success, success ? nil : "Extracted files not found")
            return
        }

        let item = itemsToDownload[currentItemIndex]
        guard currentCandidateIndex < item.urlCandidates.count else {
            // 所有候选都失败（All candidates exhausted）
            finishWithError("下载 \(item.name) 失败：所有镜像均不可达")
            return
        }

        let url = item.urlCandidates[currentCandidateIndex]
        let num = currentItemIndex + 1
        let host = url.host ?? "unknown"
        DebugLog.info("[下载] \(item.name) (\(num)/\(self.totalItems)) 来源 \(host) 候选 \(self.currentCandidateIndex + 1)/\(item.urlCandidates.count) 重试 \(self.currentCandidateRetry)/\(Self.maxRetriesPerCandidate)")

        let overall = computeOverallProgress(itemProgress: 0)
        let percent = Int(overall * 100)
        notifyProgress(num, totalItems, overall, loc("sherpa.downloading.progress", num, totalItems, percent))

        currentTask = session?.downloadTask(with: url)
        currentTask?.resume()
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoiceSherpaDownload", isDirectory: true)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let item = itemsToDownload[currentItemIndex]
        let num = currentItemIndex + 1

        // 校验响应状态码（Validate response status code）
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DebugLog.error("[下载] \(item.name) HTTP \(http.statusCode)")
            failCurrentCandidate()
            return
        }

        DebugLog.info("[下载] 完成下载 \(item.name)")

        let tmpDir = tempDir()
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let archiveURL = tmpDir.appendingPathComponent(item.archiveName)

        // 移动下载文件（Move downloaded file）
        do {
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: location, to: archiveURL)
        } catch {
            DebugLog.error("[下载] 移动下载文件失败: \(error.localizedDescription)")
            finishWithError("移动下载文件失败: \(error.localizedDescription)")
            return
        }

        // 解压（Extract）
        notifyProgress(num, totalItems, computeOverallProgress(itemProgress: 1.0), loc("sherpa.extracting", num, totalItems))

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let extractSuccess = self.extractArchive(at: archiveURL, to: item.extractDir)

            // 清理压缩包（Clean up archive）
            try? FileManager.default.removeItem(at: archiveURL)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isDownloading else { return }
                if extractSuccess {
                    DebugLog.info("[下载] 解压成功 \(item.name)")
                    // ASR 模型解压后立即扫盘写 manifest，避免后续运行时再扫
                    // (After extracting ASR archive, scan and write manifest immediately)
                    if item.name == "asr", let preset = self.targetPreset {
                        if let manifest = ModelManifest.discover(in: preset.modelDirectory) {
                            try? manifest.save(to: preset.modelDirectory)
                            DebugLog.info("[下载] manifest 写入: encoder=\(manifest.encoder) decoder=\(manifest.decoder) joiner=\(manifest.joiner)")
                        } else {
                            DebugLog.error("[下载] 解压后无法识别模型文件 \(preset.modelDirectory.path)")
                        }
                    }
                    self.advanceToNextItem()
                } else {
                    self.finishWithError("解压 \(item.name) 失败")
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let itemProgress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let num = currentItemIndex + 1
        let overall = computeOverallProgress(itemProgress: itemProgress)
        let percent = Int(overall * 100)
        notifyProgress(num, totalItems, overall, loc("sherpa.downloading.progress", num, totalItems, percent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        if error.code == NSURLErrorCancelled { return }  // 主动取消（User-initiated cancel）

        // 失败：先尝试重试当前镜像，再切下一个（Failed: retry current mirror first, then next）
        let item = itemsToDownload[currentItemIndex]
        DebugLog.error("[下载] \(item.name) 失败: \(error.localizedDescription)")
        failCurrentCandidate()
    }

    private func finishWithError(_ message: String) {
        isDownloading = false
        session?.invalidateAndCancel()
        session = nil
        targetPreset = nil
        notifyComplete(false, message)
    }

    // MARK: - 解压

    private func extractArchive(at archiveURL: URL, to targetDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", targetDir.path]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            DebugLog.error("[下载] 解压进程启动失败: \(error.localizedDescription)")
            return false
        }
    }
}
