import Foundation

/// 更新阶段独占的目录；普通结束清理，安装脚本接管后由脚本清理。
final class OwnedUpdateArtifact {
    let url: URL
    let directoryURL: URL
    private var ownsDirectory = true

    init(url: URL, directoryURL: URL) {
        self.url = url
        self.directoryURL = directoryURL
    }

    /// 必须在 URLSession 下载回调返回前复制临时文件。
    static func acquireDownload(_ temporaryURL: URL, fileManager: FileManager = .default) throws -> OwnedUpdateArtifact {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AtomVoiceUpdateArchive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let archive = directory.appendingPathComponent("update.zip")
            try fileManager.copyItem(at: temporaryURL, to: archive)
            return OwnedUpdateArtifact(url: archive, directoryURL: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// 仅在安装进程已成功启动后移交，不能把启动成功当作安装完成。
    func handOffToInstaller() {
        ownsDirectory = false
    }

    deinit {
        if ownsDirectory { try? FileManager.default.removeItem(at: directoryURL) }
    }
}
