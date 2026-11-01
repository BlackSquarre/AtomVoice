import Foundation

/// 既有下载入口共用缺失/主动替换策略与进度呈现接线。
struct SherpaDownloadCoordinator {
    let downloader: SherpaModelDownloader
    weak var reporter: SherpaDownloadReporting?

    @discardableResult
    func start(preset: SherpaModelPreset = .current, runtimeOnly: Bool = false,
               replaceModel: Bool = false, activateOnSuccess: Bool = false,
               progress: ((String) -> Void)? = nil, completion: ((Bool, String?) -> Void)? = nil) -> SherpaModelDownloader.StartResult {
        let status = SherpaResources().status(for: preset)
        let runtimePresentation = runtimeOnly || (!status.runtimeReady && status.modelReady && status.punctuationReady && !replaceModel)
        let initialKey = runtimePresentation ? "sherpa.runtime.downloading.start" : "sherpa.downloading.start"
        reporter?.updateProgress(progress: 0, message: loc(initialKey), force: false)
        downloader.addObserver(progress: { [weak reporter] _, _, overall, message in
            progress?(message)
            reporter?.updateProgress(progress: overall, message: message, force: false)
        }, complete: { [weak reporter] success, error in
            let ready = runtimeOnly ? SherpaResources().status(for: preset).runtimeReady : preset.isDownloaded
            let complete = success && ready
            if complete && activateOnSuccess { SherpaModelSelection.shared.selectPreset(preset.id) }
            reporter?.finishDownload(success: complete, error: error,
                successMessageKey: runtimePresentation ? "sherpa.runtime.download.complete" : "sherpa.download.complete",
                failureMessageKey: runtimePresentation ? "sherpa.runtime.download.failed" : "sherpa.download.failed")
            completion?(complete, error)
        })
        return downloader.startDownload(preset: preset, forceUpdateRuntime: runtimeOnly, runtimeOnly: runtimeOnly, replaceModel: replaceModel)
    }
}
