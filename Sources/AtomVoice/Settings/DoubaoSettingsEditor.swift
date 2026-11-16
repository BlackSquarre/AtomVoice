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
    private let credentialQueue = DispatchQueue(label: "AtomVoice.DoubaoSettings.credentials", qos: .userInitiated)

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

    func reloadAsync(completion: @escaping (VolcengineASRSettings) -> Void) {
        let load = self.load, readKey = self.readKey, loadCustomEndpoint = self.loadCustomEndpoint
        credentialQueue.async { [weak self] in
            var settings = load("")
            let key = readKey(settings.selectedService)
            settings.apiKey = key.string ?? ""
            let customEndpoint = settings.selectedService == .custom ? settings.endpoint : loadCustomEndpoint()
            let loadedSettings = settings
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyReads = [loadedSettings.selectedService: key]
                self.keyDrafts.removeAll()
                self.customEndpoint = customEndpoint
                self.baselineCustomEndpoint = customEndpoint
                self.baseline = .init(settings: loadedSettings)
                completion(loadedSettings)
            }
        }
    }

    func switchAsync(to service: DoubaoService, from draft: DoubaoSettingsDraft,
                     completion: @escaping (DoubaoSettingsDraft) -> Void) {
        keyDrafts[draft.service] = draft.apiKey
        if draft.service == .custom { customEndpoint = draft.endpoint }
        if keyReads[service] != nil { completion(switching(to: service, from: draft)); return }
        let readKey = self.readKey
        credentialQueue.async { [weak self] in
            let key = readKey(service)
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyReads[service] = key
                completion(self.switching(to: service, from: draft))
            }
        }
    }

    /// 后台仅处理捕获的值；部分成功的密钥结果回到主线程，重试不重复写入。
    func saveAsync(_ draft: DoubaoSettingsDraft, completion: @escaping (Bool) -> Void) {
        guard hasChanges(draft) else { completion(true); return }
        keyDrafts[draft.service] = draft.apiKey
        let drafts = keyDrafts, reads = keyReads, baseline = self.baseline
        let customEndpoint = draft.service == .custom ? draft.endpoint : self.customEndpoint
        let readKey = self.readKey, saveKey = self.saveKey, load = self.load, persist = self.persist
        credentialQueue.async { [self] in
            var nextReads = reads
            var succeeded = true
            for service in DoubaoService.allCases {
                guard let key = drafts[service] else { continue }
                let previous = nextReads[service] ?? readKey(service)
                guard key != (previous.string ?? "") else { continue }
                guard saveKey(key, service, previous) else { succeeded = false; break }
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                nextReads[service] = trimmed.isEmpty ? .notFound : .value(trimmed)
            }
            if succeeded {
                var settings = load(draft.apiKey)
                settings.service = draft.service
                settings.endpoint = draft.service.endpoint ?? draft.endpoint
                settings.customEndpoint = customEndpoint
                if draft.model != baseline?.model { settings.resourceID = draft.model.resourceID }
                settings.enableITN = draft.enableITN
                settings.enableDDC = draft.enableDDC
                settings.enableNonstream = draft.enableNonstream
                persist(settings)
            }
            let resultReads = nextReads, result = succeeded
            DispatchQueue.main.async {
                self.keyReads = resultReads
                if result {
                    self.keyDrafts.removeAll()
                    self.customEndpoint = customEndpoint
                    self.baselineCustomEndpoint = customEndpoint
                    self.baseline = draft
                }
                completion(result)
            }
        }
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

    func keyReadResult(for service: DoubaoService) -> KeychainStringReadResult {
        keyReads[service] ?? .notFound
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
