import Foundation

protocol SherpaSessionInspector: AnyObject {
    var isRecording: Bool { get }
    var requiresModelReloadOnRouteChange: Bool { get }
}

protocol SherpaLifecycleSettingsProviding {
    var normalizedRecognitionEngine: String { get }
    var sherpaModelPresetID: String { get }
    var sherpaRecognitionLanguage: String { get }
    var sherpaProvider: String { get }
    var sherpaAutoUnloadEnabled: Bool { get }
    var sherpaAutoUnloadIdleMinutes: Int { get }
}

struct AppSherpaLifecycleSettingsProvider: SherpaLifecycleSettingsProviding {
    var normalizedRecognitionEngine: String { AppSettings.normalizedRecognitionEngine }
    var sherpaModelPresetID: String { AppSettings.sherpaModelPresetID }
    var sherpaRecognitionLanguage: String { SherpaModelPreset.recognitionLanguage }
    var sherpaProvider: String { AppSettings.sherpaProvider }
    var sherpaAutoUnloadEnabled: Bool { AppSettings.sherpaAutoUnloadEnabled }
    var sherpaAutoUnloadIdleMinutes: Int { AppSettings.sherpaAutoUnloadIdleMinutes }
}

final class SherpaLifecycleCoordinator {
    private let registry: ASREngineRegistry
    private let provider: ASREngineProviding
    private let sessionInspector: () -> SherpaSessionInspector?
    private let settings: SherpaLifecycleSettingsProviding
    private let notificationCenter: NotificationCenter
    private let notificationObject: Any?
    private let scheduleAfter: (TimeInterval, DispatchWorkItem) -> Void
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var selectedRecognitionEngineCode: String
    private var selectedSherpaPresetID: String
    private var selectedSherpaRecognitionLanguage: String
    private var selectedSherpaProvider: String
    private var pendingSherpaModelRelease = false
    private var sherpaAutoUnloadWorkItem: DispatchWorkItem?

    init(
        registry: ASREngineRegistry,
        provider: ASREngineProviding,
        sessionInspector: @escaping () -> SherpaSessionInspector?,
        settings: SherpaLifecycleSettingsProviding = AppSherpaLifecycleSettingsProvider(),
        notificationCenter: NotificationCenter = .default,
        notificationObject: Any? = UserDefaults.standard,
        scheduleAfter: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    ) {
        self.registry = registry
        self.provider = provider
        self.sessionInspector = sessionInspector
        self.settings = settings
        self.notificationCenter = notificationCenter
        self.notificationObject = notificationObject
        self.scheduleAfter = scheduleAfter
        self.selectedRecognitionEngineCode = settings.normalizedRecognitionEngine
        self.selectedSherpaPresetID = settings.sherpaModelPresetID
        self.selectedSherpaRecognitionLanguage = settings.sherpaRecognitionLanguage
        self.selectedSherpaProvider = settings.sherpaProvider
    }

    /// 启动时调用一次：清理废弃 ready 标记 + 自愈 preset。
    static func migratePresetIfNeeded() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "sherpaModelsReady")

        guard let savedID = defaults.string(forKey: AppSettings.Keys.sherpaModelPresetID),
              let preset = SherpaModelPreset.allPresets.first(where: { $0.id == savedID }),
              !preset.isDownloaded else { return }

        let lang = SherpaModelPreset.recognitionLanguage
        let pool = SherpaModelPreset.presets(forRecognitionLanguage: lang)
        if let alt = pool.first(where: { $0.isDownloaded }) {
            defaults.set(alt.id, forKey: AppSettings.Keys.sherpaModelPresetID)
            DebugLog.info("[SherpaOnnx] Launch migration: \(savedID) is not downloaded, switching to downloaded preset \(alt.id)")
        }
        // 若同语言下都没有已下载的，保留原值；下次切到 sherpa 引擎时会触发下载提示
        // (If nothing downloaded in this language, keep original; next sherpa switch will prompt download)
    }

    /// 启动时调用：注册 NotificationCenter / memory pressure / 同步当前选中状态。
    func start() {
        syncSelectedSettings()
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.sessionInspector()?.isRecording != true else { return }
            DebugLog.info("[AppDelegate] Critical memory pressure, releasing Sherpa model")
            self.releaseIfNeeded()
        }
        memoryPressureSource?.resume()

        notificationCenter.addObserver(
            self,
            selector: #selector(recognitionEngineDefaultsDidChange),
            name: AppSettings.recognitionEngineSettingsDidChangeNotification,
            object: notificationObject
        )
    }

    /// applicationWillTerminate / deinit 调用。
    func stop() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        cancelAutoUnload()
        notificationCenter.removeObserver(
            self,
            name: AppSettings.recognitionEngineSettingsDidChangeNotification,
            object: notificationObject
        )
    }

    /// 录音结束后调用（从 sessionDidEnd 转发）。
    func performPostRecordingCleanup() {
        releaseSherpaModelsAfterRecordingIfNeeded()
        scheduleSherpaAutoUnloadIfNeeded()
    }

    /// 取消 idle auto-unload（FnKey down / headphone trigger 等调用）。
    func cancelAutoUnload() {
        sherpaAutoUnloadWorkItem?.cancel()
        sherpaAutoUnloadWorkItem = nil
    }

    /// 释放模型（外部触发用，如内存压力外部传入）。
    func releaseIfNeeded() {
        cancelAutoUnload()
        pendingSherpaModelRelease = false
        provider.releaseSherpaEngine()
    }

    @objc private func recognitionEngineDefaultsDidChange() {
        let newCode = settings.normalizedRecognitionEngine
        let previousCode = selectedRecognitionEngineCode
        selectedRecognitionEngineCode = newCode

        let newSherpaPresetID = settings.sherpaModelPresetID
        let newSherpaRecognitionLanguage = settings.sherpaRecognitionLanguage
        let newSherpaProvider = settings.sherpaProvider
        let didChangeSherpaSelection =
            newSherpaPresetID != selectedSherpaPresetID ||
            newSherpaRecognitionLanguage != selectedSherpaRecognitionLanguage ||
            newSherpaProvider != selectedSherpaProvider
        selectedSherpaPresetID = newSherpaPresetID
        selectedSherpaRecognitionLanguage = newSherpaRecognitionLanguage
        selectedSherpaProvider = newSherpaProvider

        guard newCode != previousCode else {
            if didChangeSherpaSelection {
                handleSherpaSelectionChange()
            }
            updateSherpaAutoUnloadConfiguration()
            return
        }

        guard registry.isSherpa(previousCode), !registry.isSherpa(newCode) else {
            if didChangeSherpaSelection {
                handleSherpaSelectionChange()
            }
            updateSherpaAutoUnloadConfiguration()
            return
        }

        if sessionInspector()?.isRecording == true &&
            sessionInspector()?.requiresModelReloadOnRouteChange == true {
            pendingSherpaModelRelease = true
            return
        }

        releaseIfNeeded()
    }

    private func handleSherpaSelectionChange() {
        guard provider.hasSherpaEngine else { return }

        if sessionInspector()?.isRecording == true &&
            sessionInspector()?.requiresModelReloadOnRouteChange == true {
            pendingSherpaModelRelease = true
            DebugLog.info("[AppDelegate] Sherpa preset changed, releasing old model after current recording")
            return
        }

        DebugLog.info("[AppDelegate] Sherpa preset changed, releasing old model")
        releaseIfNeeded()
    }

    private func syncSelectedSettings() {
        selectedRecognitionEngineCode = settings.normalizedRecognitionEngine
        selectedSherpaPresetID = settings.sherpaModelPresetID
        selectedSherpaRecognitionLanguage = settings.sherpaRecognitionLanguage
        selectedSherpaProvider = settings.sherpaProvider
    }

    private func sherpaAutoUnloadEnabled() -> Bool {
        settings.sherpaAutoUnloadEnabled
    }

    private func sherpaAutoUnloadDelay() -> TimeInterval {
        TimeInterval(settings.sherpaAutoUnloadIdleMinutes * 60)
    }

    private func scheduleSherpaAutoUnloadIfNeeded() {
        cancelAutoUnload()
        guard sherpaAutoUnloadEnabled(),
              sessionInspector()?.isRecording != true,
              selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
              provider.isSherpaModelLoaded else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sherpaAutoUnloadWorkItem = nil
            guard self.sessionInspector()?.isRecording != true,
                  self.selectedRecognitionEngineCode == ASREngineRegistry.sherpaCode,
                  self.provider.isSherpaModelLoaded else { return }
            DebugLog.info("[AppDelegate] Sherpa idle timeout reached, auto-releasing local model")
            self.releaseIfNeeded()
        }
        sherpaAutoUnloadWorkItem = workItem
        scheduleAfter(sherpaAutoUnloadDelay(), workItem)
    }

    private func updateSherpaAutoUnloadConfiguration() {
        if selectedRecognitionEngineCode != ASREngineRegistry.sherpaCode || !sherpaAutoUnloadEnabled() {
            cancelAutoUnload()
        }
        scheduleSherpaAutoUnloadIfNeeded()
    }

    private func releaseSherpaModelsAfterRecordingIfNeeded() {
        guard pendingSherpaModelRelease else { return }
        releaseIfNeeded()
    }
}

final class SessionInspectorAdapter: SherpaSessionInspector {
    weak var controller: RecordingSessionController?

    init(controller: RecordingSessionController?) {
        self.controller = controller
    }

    var isRecording: Bool {
        controller?.isRecording == true
    }

    var requiresModelReloadOnRouteChange: Bool {
        controller?.activeRecognitionSession?.requiresModelReloadOnRouteChange == true
    }
}
