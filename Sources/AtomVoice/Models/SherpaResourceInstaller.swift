import Foundation

/// 一次下载的身份贯穿查询、网络与落盘；取消与提交在同一锁内排序。
final class SherpaInstallAttempt {
    let id = UUID()
    let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoiceSherpaDownload-\(UUID().uuidString)", isDirectory: true)
    deinit {
        let directory = workingDirectory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }
    private let lock = NSRecursiveLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func cancel() { lock.lock(); active = false; lock.unlock() }
    func commit<T>(_ work: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return try work()
    }
}

/// 准备好替换内容之后才触碰正式路径，取消/登记失败可恢复原目录。
final class SherpaInstalledDirectory {
    let url: URL
    private let backup: URL?
    private var finalized = false
    init(url: URL, backup: URL?) { self.url = url; self.backup = backup }
    func commit() {
        finalized = true
        if let backup { try? FileManager.default.removeItem(at: backup) }
    }
    func rollback() {
        guard !finalized else { return }
        finalized = true
        let fm = FileManager.default
        let discarded = url.deletingLastPathComponent().appendingPathComponent(".AtomVoice-rollback-\(UUID().uuidString)", isDirectory: true)
        do {
            if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: discarded) }
            if let backup { try fm.moveItem(at: backup, to: url) }
            // 清理可很大；回滚本身只做 rename，不占用 attempt 提交锁。
            DispatchQueue.global(qos: .utility).async { try? fm.removeItem(at: discarded) }
        } catch {
            DebugLog.error("[SherpaOnnx] Could not restore installation; retained backup: \(error)")
        }
    }
    deinit { rollback() }
}

/// 大文件复制在准备阶段完成，安装阶段只持有 sibling rename 的短事务。
final class SherpaPreparedDirectory {
    let target: URL
    private var staged: URL?
    init(target: URL, staged: URL?) { self.target = target; self.staged = staged }
    func install() throws -> SherpaInstalledDirectory {
        guard let staged else {
            let installed = SherpaInstalledDirectory(url: target, backup: nil)
            installed.commit()
            return installed
        }
        let fm = FileManager.default
        let backup = fm.fileExists(atPath: target.path)
            ? target.deletingLastPathComponent().appendingPathComponent(".AtomVoice-backup-\(UUID().uuidString)", isDirectory: true) : nil
        if let backup { try fm.moveItem(at: target, to: backup) }
        do { try fm.moveItem(at: staged, to: target) }
        catch {
            if let backup { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
        self.staged = nil
        return SherpaInstalledDirectory(url: target, backup: backup)
    }
    deinit { if let staged { try? FileManager.default.removeItem(at: staged) } }
}

struct SherpaResourceInstaller {
    static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    static func prepareDirectory(from source: URL, to target: URL,
                                 copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws -> SherpaPreparedDirectory {
        if sameLocation(source, target) { return .init(target: target, staged: nil) }
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".AtomVoice-install-\(UUID().uuidString)", isDirectory: true)
        do { try copy(source, staged) }
        catch { try? fm.removeItem(at: staged); throw error }
        return .init(target: target, staged: staged)
    }

    static func replaceDirectory(from source: URL, to target: URL) throws -> SherpaInstalledDirectory {
        try prepareDirectory(from: source, to: target).install()
    }

    static func removeModel(_ preset: SherpaModelPreset, paths: SherpaResourcePaths = .current,
                            store: SherpaImportedPresetStore = .shared,
                            selection: SherpaModelSelection = .shared) throws {
        let fm = FileManager.default
        let target = paths.model(preset)
        let tombstone = paths.models.appendingPathComponent(".AtomVoice-delete-\(UUID().uuidString)", isDirectory: true)
        let record = store.records.first { $0.id == preset.id }
        let wasSelected = selection.isSelectedPresetID(preset.id)
        try fm.moveItem(at: target, to: tombstone)
        if preset.isImported && !store.remove(id: preset.id) {
            try? fm.moveItem(at: tombstone, to: target)
            throw CocoaError(.fileWriteUnknown)
        }
        do { try fm.removeItem(at: tombstone) }
        catch {
            try? fm.moveItem(at: tombstone, to: target)
            if let record { _ = store.add(record) }
            throw error
        }
        if preset.isImported && wasSelected {
            selection.selectPreset(selection.defaultModelID(for: preset.language))
        }
        NotificationCenter.default.post(name: .sherpaResourcesDidChange, object: preset.id)
    }

    static func replaceFile(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent().appendingPathComponent(".AtomVoice-file-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: target) }
    }
}
