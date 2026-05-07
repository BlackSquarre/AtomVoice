import Foundation
import os.log

private let logger = Logger(subsystem: "com.blacksquarre.AtomVoice", category: "SherpaDownloader")

/// Sherpa 模型下载管理器（Sherpa Model Download Manager）
/// 三个组件：Runtime dylib、ASR 模型、标点模型（Three components: Runtime dylib, ASR model, punctuation model）
/// 下载 → 解压 → 清理临时文件（Download → Extract → Clean up temp files）
final class SherpaModelDownloader: NSObject, URLSessionDownloadDelegate {
    private static let runtimeArchiveRootName = "sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib"
    private static let requiredRuntimeLibs = [
        "libsherpa-onnx-c-api.dylib",
        "libonnxruntime.1.24.4.dylib",
    ]

    struct DownloadItem {
        let name: String
        let url: URL
        let extractDir: URL   // 解压目标目录（父目录）（Extract target directory (parent)）
        let archiveName: String
    }

    static let shared = SherpaModelDownloader()

    /// 下载进度回调（主线程）（Download progress callback (main thread)）
    /// - Parameters:
    ///   - currentItem: 当前第几个（1-based）（Current item number (1-based)）
    ///   - totalItems: 总数（Total count）
    ///   - itemProgress: 当前文件进度 0.0~1.0（Current file progress 0.0~1.0）
    ///   - message: 状态文字（Status message）
    var onProgress: ((Int, Int, Double, String) -> Void)?
    var onComplete: ((Bool, String?) -> Void)?

    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var itemsToDownload: [DownloadItem] = []
    private var currentItemIndex = 0
    private var totalItems = 0
    private var verificationPreset: SherpaModelPreset?
    private(set) var isDownloading = false

    /// Sherpa 运行所需文件清单（Sherpa runtime required file list）
    static var requiredFiles: [(name: String, url: URL)] {
        requiredFiles(for: SherpaModelPreset.current)
    }

    private static func requiredFiles(for preset: SherpaModelPreset) -> [(name: String, url: URL)] {
        let rt = SherpaOnnxRecognizerController.runtimeLibDirectory
        let asr = preset.modelDirectory
        let punct = SherpaOnnxRecognizerController.punctuationModelDirectory

        return [
            ("libsherpa-onnx-c-api.dylib", rt.appendingPathComponent("libsherpa-onnx-c-api.dylib")),
            ("libonnxruntime.1.24.4.dylib", rt.appendingPathComponent("libonnxruntime.1.24.4.dylib")),
            (preset.encoderFile, asr.appendingPathComponent(preset.encoderFile)),
            (preset.decoderFile, asr.appendingPathComponent(preset.decoderFile)),
            (preset.joinerFile, asr.appendingPathComponent(preset.joinerFile)),
            (preset.tokensFile, asr.appendingPathComponent(preset.tokensFile)),
            ("model.int8.onnx", punct.appendingPathComponent("model.int8.onnx")),
        ]
    }

    static var missingRequiredFiles: [(name: String, url: URL)] {
        missingRequiredFiles(for: SherpaModelPreset.current)
    }

    private static func missingRequiredFiles(for preset: SherpaModelPreset) -> [(name: String, url: URL)] {
        requiredFiles(for: preset).filter { !isUsableFile($0.url) }
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
                guard isUsableFile(source), !isUsableFile(target) else { continue }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                print("[SherpaOnnx] 已修复运行库路径: \(target.path)")
            }
        } catch {
            print("[SherpaOnnx] 修复运行库路径失败: \(error)")
            return false
        }

        return allModelsReady(for: preset)
    }

    /// 是否所有模型都已存在。只在下载完成、启动自愈或错误恢复时调用。（Whether all models are present. Only called after download completion, startup self-repair, or error recovery.）
    static var allModelsReady: Bool {
        allModelsReady(for: SherpaModelPreset.current)
    }

    static func allModelsReady(for preset: SherpaModelPreset) -> Bool {
        missingRequiredFiles(for: preset).isEmpty
    }

    static func printMissingRequiredFiles(for preset: SherpaModelPreset = SherpaModelPreset.current) {
        let missingFiles = missingRequiredFiles(for: preset)
        if missingFiles.isEmpty {
            print("[SherpaOnnx] 必需文件都存在，但模型仍无法加载，可能是文件损坏或版本不兼容")
            return
        }

        print("[SherpaOnnx] 必需文件缺失或为空：")
        for file in missingFiles {
            print("[SherpaOnnx] - \(file.name): \(file.url.path)")
        }
    }

    /// 开始下载所有缺失的模型（Start downloading all missing models）
    func startDownload() {
        startDownload(preset: SherpaModelPreset.current)
    }

    /// 开始下载指定预设模型（Start downloading specified preset model）
    func startDownload(preset: SherpaModelPreset) {
        guard !isDownloading else { return }
        isDownloading = true
        verificationPreset = preset

        // 创建目录（Create directories）
        try? SherpaOnnxRecognizerController.createSupportDirectories()

        // 构建下载列表：运行库 + 指定模型 + 标点模型
        let runtimeItem = DownloadItem(
            name: "runtime",
            url: SherpaModelPreset.needsMirror
                ? URL(string: "https://ghproxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib.tar.bz2")!
                : URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib.tar.bz2")!,
            extractDir: SherpaOnnxRecognizerController.supportDirectory,
            archiveName: "sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib.tar.bz2"
        )

        let asrItem = DownloadItem(
            name: "asr",
            url: preset.downloadURL,
            extractDir: SherpaOnnxRecognizerController.modelsDirectory,
            archiveName: preset.archiveName
        )

        let punctItem = DownloadItem(
            name: "punct",
            url: SherpaModelPreset.needsMirror
                ? URL(string: "https://ghproxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2")!
                : URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2")!,
            extractDir: SherpaOnnxRecognizerController.modelsDirectory,
            archiveName: "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2"
        )

        // 检查哪些需要下载
        itemsToDownload = []
        let runtimeMissing = Self.requiredRuntimeLibs.contains {
            !Self.isUsableFile(SherpaOnnxRecognizerController.runtimeLibDirectory.appendingPathComponent($0))
        }
        if runtimeMissing {
            itemsToDownload.append(runtimeItem)
        }
        if !preset.isDownloaded {
            itemsToDownload.append(asrItem)
        }
        if !Self.isUsableFile(SherpaOnnxRecognizerController.punctuationModelDirectory.appendingPathComponent("model.int8.onnx")) {
            itemsToDownload.append(punctItem)
        }

        guard !itemsToDownload.isEmpty else {
            isDownloading = false
            let success = Self.allModelsReady(for: preset) || Self.repairExtractedFilesIfNeeded(for: preset)
            verificationPreset = nil
            if success {
                UserDefaults.standard.set(true, forKey: "sherpaModelsReady")
            } else {
                Self.printMissingRequiredFiles(for: preset)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onComplete?(success, success ? nil : "Extracted files not found")
                self?.onProgress = nil
                self?.onComplete = nil
            }
            return
        }

        currentItemIndex = 0
        totalItems = itemsToDownload.count

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        downloadNext()
    }

    /// 取消下载（Cancel download）
    func cancel() {
        currentTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        verificationPreset = nil
        isDownloading = false
    }

    // MARK: - Private

    private func downloadNext() {
        guard currentItemIndex < itemsToDownload.count else {
            // 全部完成，验证文件确实存在（All done, verify files actually exist）
            isDownloading = false
            session?.finishTasksAndInvalidate()
            session = nil

            let preset = verificationPreset ?? SherpaModelPreset.current
            let success = Self.allModelsReady(for: preset) || Self.repairExtractedFilesIfNeeded(for: preset)
            verificationPreset = nil
            if success {
                UserDefaults.standard.set(true, forKey: "sherpaModelsReady")
                logger.info("[下载] 所有模型验证通过，已标记 sherpaModelsReady = true")
            } else {
                Self.printMissingRequiredFiles(for: preset)
            }
            DispatchQueue.main.async { [weak self] in
                if success {
                    self?.onComplete?(true, nil)
                } else {
                    self?.onComplete?(false, "Extracted files not found")
                }
                self?.onProgress = nil
                self?.onComplete = nil
            }
            return
        }

        let item = itemsToDownload[currentItemIndex]
        let num = currentItemIndex + 1
        logger.info("[下载] 开始 \(item.name, privacy: .public) (\(num)/\(self.totalItems))")

        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(num, self?.totalItems ?? 0, 0, loc("sherpa.downloading", num, self?.totalItems ?? 0))
        }

        currentTask = session?.downloadTask(with: item.url)
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
        logger.info("[下载] 完成下载 \(item.name, privacy: .public)")

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
            logger.error("[下载] 移动下载文件失败: \(error.localizedDescription, privacy: .public)")
            finishWithError("移动下载文件失败: \(error.localizedDescription)")
            return
        }

        // 解压（Extract）
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(num, self?.totalItems ?? 0, 1.0, loc("sherpa.extracting", num, self?.totalItems ?? 0))
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let extractSuccess = self.extractArchive(at: archiveURL, to: item.extractDir)

            // 清理压缩包（Clean up archive）
            try? FileManager.default.removeItem(at: archiveURL)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isDownloading else { return }
                if extractSuccess {
                    logger.info("[下载] 解压成功 \(item.name, privacy: .public)")
                    self.currentItemIndex += 1
                    self.downloadNext()
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

        let percent = Int(itemProgress * 100)
        let msg = loc("sherpa.downloading.progress", num, totalItems, percent)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(num, self?.totalItems ?? 0, itemProgress, msg)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }  // 主动取消（User-initiated cancel）
            logger.error("[下载] 下载失败: \(error.localizedDescription, privacy: .public)")
            finishWithError("下载失败: \(error.localizedDescription)")
        }
    }

    private func finishWithError(_ message: String) {
        isDownloading = false
        session?.invalidateAndCancel()
        session = nil
        verificationPreset = nil
        DispatchQueue.main.async { [weak self] in
            self?.onComplete?(false, message)
            self?.onProgress = nil
            self?.onComplete = nil
        }
    }

    private static func isUsableFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
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
            logger.error("[下载] 解压进程启动失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
