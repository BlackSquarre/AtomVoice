import Foundation

struct DoubaoSettingsDraft: Equatable {
    var apiKey: String
    var model: DoubaoModelKind
    var endpoint: String
    var enableITN: Bool
    var enableDDC: Bool
    var enableNonstream: Bool

    init(settings: VolcengineASRSettings) {
        apiKey = settings.apiKey
        model = DoubaoModelKind.from(resourceID: settings.resourceID)
        endpoint = settings.endpoint
        enableITN = settings.enableITN
        enableDDC = settings.enableDDC
        enableNonstream = settings.enableNonstream
    }
}

/// 两个既有豆包设置入口共用草稿和提交顺序，不增加表单校验条件。
final class DoubaoSettingsEditor {
    private(set) var baseline: DoubaoSettingsDraft?
    private var keyRead: KeychainStringReadResult = .notFound
    private let readKey: () -> KeychainStringReadResult
    private let load: (String) -> VolcengineASRSettings
    private let saveKey: (String, KeychainStringReadResult) -> Bool
    private let persist: (VolcengineASRSettings) -> Void

    init(readKey: @escaping () -> KeychainStringReadResult = { VolcengineASRSettings.savedAPIKeyReadResult },
         load: @escaping (String) -> VolcengineASRSettings = { VolcengineASRSettings.load(apiKey: $0) },
         saveKey: @escaping (String, KeychainStringReadResult) -> Bool = { VolcengineASRSettings.saveAPIKey($0, previousRead: $1) },
         persist: @escaping (VolcengineASRSettings) -> Void = { $0.persistNonSecretFields() }) {
        self.readKey = readKey
        self.load = load
        self.saveKey = saveKey
        self.persist = persist
    }

    func reload() -> VolcengineASRSettings {
        keyRead = readKey()
        let settings = load(keyRead.string ?? "")
        baseline = .init(settings: settings)
        return settings
    }

    func hasChanges(_ draft: DoubaoSettingsDraft) -> Bool { baseline != draft }

    func save(_ draft: DoubaoSettingsDraft) -> Bool {
        guard hasChanges(draft) else { return true }
        if draft.apiKey != baseline?.apiKey {
            guard saveKey(draft.apiKey, keyRead) else { return false }
            let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            keyRead = key.isEmpty ? .notFound : .value(key)
        }
        var settings = load(draft.apiKey)
        settings.endpoint = draft.endpoint
        settings.resourceID = draft.model.resourceID
        settings.enableITN = draft.enableITN
        settings.enableDDC = draft.enableDDC
        settings.enableNonstream = draft.enableNonstream
        persist(settings)
        baseline = draft
        return true
    }
}
