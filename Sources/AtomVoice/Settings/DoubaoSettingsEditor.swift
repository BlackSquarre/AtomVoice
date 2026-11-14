import Foundation

struct DoubaoSettingsDraft: Equatable {
    var service: DoubaoService
    var apiKey: String
    var model: DoubaoModelKind
    var endpoint: String
    var enableITN: Bool
    var enableDDC: Bool
    var enableNonstream: Bool

    init(settings: VolcengineASRSettings) {
        service = settings.selectedService
        apiKey = settings.apiKey
        model = DoubaoModelKind.from(resourceID: settings.resourceID)
        endpoint = settings.endpoint
        enableITN = settings.enableITN
        enableDDC = settings.enableDDC
        enableNonstream = settings.enableNonstream
    }
}

/// 服务切换只更新草稿；保存时先提交各服务密钥，成功后再切换生效配置。
final class DoubaoSettingsEditor {
    private(set) var baseline: DoubaoSettingsDraft?
    private var keyReads: [DoubaoService: KeychainStringReadResult] = [:]
    private var keyDrafts: [DoubaoService: String] = [:]
    private var customEndpoint = ""
    private var baselineCustomEndpoint = ""
    private let readKey: (DoubaoService) -> KeychainStringReadResult
    private let load: (String) -> VolcengineASRSettings
    private let saveKey: (String, DoubaoService, KeychainStringReadResult) -> Bool
    private let persist: (VolcengineASRSettings) -> Void
    private let loadCustomEndpoint: () -> String

    init(readKey: @escaping (DoubaoService) -> KeychainStringReadResult = { VolcengineASRSettings.readAPIKey(for: $0) },
         load: @escaping (String) -> VolcengineASRSettings = { VolcengineASRSettings.load(apiKey: $0) },
         saveKey: @escaping (String, DoubaoService, KeychainStringReadResult) -> Bool = { VolcengineASRSettings.saveAPIKey($0, for: $1, previousRead: $2) },
         persist: @escaping (VolcengineASRSettings) -> Void = { $0.persistNonSecretFields() },
         loadCustomEndpoint: @escaping () -> String = {
             AppSettings.backend.string(forKey: AppSettings.Keys.doubaoASRCustomEndpoint, default: VolcengineASRSettings.defaultEndpoint)
         }) {
        self.readKey = readKey
        self.load = load
        self.saveKey = saveKey
        self.persist = persist
        self.loadCustomEndpoint = loadCustomEndpoint
    }

    func reload() -> VolcengineASRSettings {
        keyReads.removeAll()
        keyDrafts.removeAll()
        // 先读取非密钥配置，再按实际选中的服务读取钥匙串。
        var settings = load("")
        let keyRead = readKey(settings.selectedService)
        keyReads[settings.selectedService] = keyRead
        settings.apiKey = keyRead.string ?? ""
        customEndpoint = settings.selectedService == .custom ? settings.endpoint : loadCustomEndpoint()
        baselineCustomEndpoint = customEndpoint
        baseline = .init(settings: settings)
        return settings
    }

    func switching(to service: DoubaoService, from draft: DoubaoSettingsDraft) -> DoubaoSettingsDraft {
        keyDrafts[draft.service] = draft.apiKey
        if draft.service == .custom { customEndpoint = draft.endpoint }
        if keyReads[service] == nil { keyReads[service] = readKey(service) }
        var next = draft
        next.service = service
        next.apiKey = keyDrafts[service] ?? keyReads[service]?.string ?? ""
        next.endpoint = service.endpoint ?? customEndpoint
        return next
    }

    func hasChanges(_ draft: DoubaoSettingsDraft) -> Bool {
        baseline != draft || customEndpoint != baselineCustomEndpoint
            || keyDrafts.contains { service, key in key != (keyReads[service]?.string ?? "") }
    }

    func save(_ draft: DoubaoSettingsDraft) -> Bool {
        guard hasChanges(draft) else { return true }
        keyDrafts[draft.service] = draft.apiKey
        for service in DoubaoService.allCases {
            guard let key = keyDrafts[service] else { continue }
            let previous = keyReads[service] ?? readKey(service)
            guard key != (previous.string ?? "") else { continue }
            guard saveKey(key, service, previous) else { return false }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            keyReads[service] = trimmed.isEmpty ? .notFound : .value(trimmed)
        }
        var settings = load(draft.apiKey)
        settings.service = draft.service
        settings.endpoint = draft.service.endpoint ?? draft.endpoint
        if draft.service == .custom { customEndpoint = draft.endpoint }
        settings.customEndpoint = customEndpoint
        // 未切换模型时保留并发版等已有资源 ID，不能因切服务将其改成时长版。
        if draft.model != baseline?.model { settings.resourceID = draft.model.resourceID }
        settings.enableITN = draft.enableITN
        settings.enableDDC = draft.enableDDC
        settings.enableNonstream = draft.enableNonstream
        persist(settings)
        keyDrafts.removeAll()
        baselineCustomEndpoint = customEndpoint
        baseline = draft
        return true
    }
}
