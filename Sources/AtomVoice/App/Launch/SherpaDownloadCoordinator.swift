import Foundation

/// 既有下载入口共用缺失/主动替换策略与进度呈现接线。
struct SherpaDownloadCoordinator {
    let downloader: SherpaModelDownloader
    weak var reporter: SherpaDownloadReporting?

    @discardableResult
    func start(preset: SherpaModelPreset = .current, runtimeOnly: Bool = false,
               replaceModel: Bool = false, activateOnSuccess: Bool = false,
               runtimeRelease: SherpaRuntimeRelease? = nil,
               progress: ((String) -> Void)? = nil, completion: ((Bool, String?) -> Void)? = nil) -> SherpaModelDownloader.StartResult {
        // 运行库更新不能把正在进行的普通模型下载当成自己的更新成功。
        if runtimeOnly && downloader.isDownloading { return .alreadyDownloading }
        let initialKey = runtimeOnly ? "sherpa.runtime.downloading.start" : "sherpa.downloading.start"
        reporter?.updateProgress(progress: 0, message: loc(initialKey), force: false)
        let paths = downloader.resourcePaths
        // 初始状态和完成校验共用一次串行后台队列；主线程仅应用仍属于本轮的呈现。
        let inspectionQueue = DispatchQueue(label: "AtomVoice.SherpaDownload.inspection", qos: .userInitiated)
        var runtimePresentation = runtimeOnly
        var expectedGeneration = downloader.attemptGeneration
        var hasProgress = false
        var finished = false
        inspectionQueue.async { [weak reporter] in
            let status = SherpaResources(paths: paths).status(for: preset)
            runtimePresentation = runtimeOnly || (!status.runtimeReady && status.modelReady && status.punctuationReady && !replaceModel)
            let key = runtimePresentation ? "sherpa.runtime.downloading.start" : "sherpa.downloading.start"
            DispatchQueue.main.async {
                guard downloader.attemptGeneration == expectedGeneration, !finished, !hasProgress else { return }
                reporter?.updateProgress(progress: 0, message: loc(key), force: false)
            }
        }
        downloader.addObserver(progress: { [weak reporter] _, _, overall, message in
            hasProgress = true
            progress?(message)
            reporter?.updateProgress(progress: overall, message: message, force: false)
        }, complete: { [weak reporter] success, error in
            finished = true
            inspectionQueue.async {
                let ready = success && (runtimeOnly
                    ? SherpaResources(paths: paths).runtimeReady
                    : ModelManifest.inspect(in: paths.model(preset)) != nil)
                let complete = success && ready
                let successKey = runtimePresentation ? "sherpa.runtime.download.complete" : "sherpa.download.complete"
                let failureKey = runtimePresentation ? "sherpa.runtime.download.failed" : "sherpa.download.failed"
                DispatchQueue.main.async {
                    guard downloader.attemptGeneration == expectedGeneration else {
                        completion?(false, error)
                        return
                    }
                    if complete && activateOnSuccess { SherpaModelSelection.shared.selectPreset(preset.id) }
                    reporter?.finishDownload(success: complete, error: error,
                        successMessageKey: successKey, failureMessageKey: failureKey)
                    completion?(complete, error)
                }
            }
        })
        let result = downloader.startDownload(preset: preset, forceUpdateRuntime: runtimeOnly, runtimeOnly: runtimeOnly,
                                              replaceModel: replaceModel, runtimeRelease: runtimeRelease)
        expectedGeneration = downloader.attemptGeneration
        return result
    }
}
