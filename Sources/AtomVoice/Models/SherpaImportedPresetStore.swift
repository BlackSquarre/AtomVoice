import Foundation

/// 用户手动导入的 Sherpa 模型记录（User-imported Sherpa model record）
struct SherpaImportedPresetRecord: Codable, Equatable {
    let id: String                  // 显示用 ID（show id, default = extractedDirName）
    let language: String            // 用户指定的识别语言（user-chosen recognition language）
    let extractedDirName: String    // models/ 下的实际目录名（actual directory name under models/）
    let sizeMB: Int
    let importedAt: Date
}

/// 已导入预设的持久化容器（Persistence container for imported presets）
final class SherpaImportedPresetStore {
    static let shared = SherpaImportedPresetStore()
    private static let key = AppSettings.Keys.sherpaImportedPresets

    private let backend: SettingsBackend
    private let lock = NSRecursiveLock()
    private var storedRecords: [SherpaImportedPresetRecord] = []
    var records: [SherpaImportedPresetRecord] {
        lock.lock(); defer { lock.unlock() }
        return storedRecords
    }

    init(backend: SettingsBackend = AppSettings.backend) { self.backend = backend; reload() }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let data = backend.data(forKey: Self.key) else {
            storedRecords = []
            return
        }
        storedRecords = (try? JSONDecoder().decode([SherpaImportedPresetRecord].self, from: data)) ?? []
    }

    @discardableResult
    func save() -> Bool { persist(records) }

    private func persist(_ next: [SherpaImportedPresetRecord]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(next) else { return false }
        backend.set(data, forKey: Self.key)
        guard backend.data(forKey: Self.key) == data else { return false }
        storedRecords = next
        return true
    }

    @discardableResult
    func add(_ record: SherpaImportedPresetRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return persist(storedRecords.filter { $0.id != record.id } + [record])
    }

    @discardableResult
    func remove(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return persist(storedRecords.filter { $0.id != id })
    }

    /// 转成 SherpaModelPreset 列表，便于和内置 preset 统一处理
    /// (Convert to SherpaModelPreset list for uniform handling with built-ins)
    func presets() -> [SherpaModelPreset] {
        records.map { r in
            SherpaModelPreset(
                id: r.id,
                language: r.language,
                archiveURL: nil,
                archiveName: nil,
                extractedDirName: r.extractedDirName,
                sizeMB: r.sizeMB,
                isImported: true
            )
        }
    }
}
