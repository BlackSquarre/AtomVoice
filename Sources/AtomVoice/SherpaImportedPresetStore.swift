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
    private static let key = "sherpaImportedPresets"

    private(set) var records: [SherpaImportedPresetRecord] = []

    init() { reload() }

    func reload() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            records = []
            return
        }
        records = (try? JSONDecoder().decode([SherpaImportedPresetRecord].self, from: data)) ?? []
    }

    func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func add(_ record: SherpaImportedPresetRecord) {
        // 同 id 替换；防止重复（Replace by id; prevent duplicates）
        records.removeAll { $0.id == record.id }
        records.append(record)
        save()
    }

    func remove(id: String) {
        records.removeAll { $0.id == id }
        save()
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
