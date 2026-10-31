import Foundation

protocol DownloadCapsulePresenting: AnyObject {
    var presentationID: Int { get }
    var isShowingDownloadPresentation: Bool { get }
    func showDownloadProgress(_ text: String, progress: Double)
    func updateText(_ text: String, completion: (() -> Void)?)
    func showError(_ message: String, dismissAfter: TimeInterval)
    func dismiss(completion: (() -> Void)?)
}

extension CapsuleWindowController: DownloadCapsulePresenting {}

/// Sherpa 下载状态对外报告接口；解耦设置面板和 AppDelegate 持有的 presenter。
/// (Outward-facing Sherpa download reporting; decouples settings panels from the AppDelegate-owned presenter.)
protocol SherpaDownloadReporting: AnyObject {
    func updateProgress(progress: Double, message: String, force: Bool)
    func finishDownload(success: Bool, error: String?)
    func finishDownload(success: Bool, error: String?, successMessageKey: String, failureMessageKey: String)
}

final class SherpaDownloadCapsulePresenter: SherpaDownloadReporting {
    private struct PendingCompletion {
        let success: Bool
        let error: String?
        let successMessageKey: String
        let failureMessageKey: String
    }

    private weak var capsulePresenter: (any DownloadCapsulePresenting)?
    private weak var capsuleWindow: CapsuleWindowController?
    private let isRecording: () -> Bool
    private let now: () -> Date
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private var sherpaDownloadCapsuleActive = false
    private var sherpaDownloadDeferredByRecording = false
    private var sherpaDownloadCapsuleMessage: String?
    private var sherpaDownloadCapsuleProgress: Double = 0
    private var sherpaDownloadCapsuleLastUpdate = Date.distantPast
    private var pendingCompletion: PendingCompletion?
    private var suppressCurrentDownloadPresentation = false

    convenience init(
        capsuleWindow: CapsuleWindowController,
        isRecording: @escaping () -> Bool
    ) {
        self.init(capsulePresenter: capsuleWindow, capsuleWindow: capsuleWindow, isRecording: isRecording)
    }

    init(
        capsulePresenter: any DownloadCapsulePresenting,
        capsuleWindow: CapsuleWindowController? = nil,
        isRecording: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() },
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.capsulePresenter = capsulePresenter
        self.capsuleWindow = capsuleWindow
        self.isRecording = isRecording
        self.now = now
        self.scheduleAfter = scheduleAfter
        self.capsuleWindow?.onDidDismiss = { [weak self] reason in
            self?.handleCapsuleDidDismiss(reason: reason)
        }
    }

    /// 收到下载进度时调用（节流逻辑内部处理，每 250ms 最多刷一次）。
    func updateProgress(progress: Double, message: String, force: Bool) {
        if force { suppressCurrentDownloadPresentation = false }
        sherpaDownloadCapsuleActive = true
        sherpaDownloadCapsuleMessage = message
        sherpaDownloadCapsuleProgress = min(max(progress, 0), 1)
        pendingCompletion = nil
        guard !suppressCurrentDownloadPresentation, canPresentDownloadCapsule else {
            sherpaDownloadDeferredByRecording = true
            return
        }

        let currentTime = now()
        guard force || currentTime.timeIntervalSince(sherpaDownloadCapsuleLastUpdate) >= 0.25 else { return }
        sherpaDownloadCapsuleLastUpdate = currentTime
        sherpaDownloadDeferredByRecording = false
        capsulePresenter?.showDownloadProgress(message, progress: sherpaDownloadCapsuleProgress)
    }

    /// 下载结束时调用，决定是否展示完成/失败胶囊。
    func finishDownload(success: Bool, error: String?) {
        finishDownload(
            success: success,
            error: error,
            successMessageKey: "sherpa.download.complete",
            failureMessageKey: "sherpa.download.failed"
        )
    }

    func finishDownload(success: Bool, error: String?, successMessageKey: String, failureMessageKey: String) {
        sherpaDownloadCapsuleActive = false
        sherpaDownloadDeferredByRecording = false
        sherpaDownloadCapsuleMessage = nil
        sherpaDownloadCapsuleProgress = success ? 1 : sherpaDownloadCapsuleProgress
        let wasSuppressed = suppressCurrentDownloadPresentation
        suppressCurrentDownloadPresentation = false
        if success && wasSuppressed {
            pendingCompletion = nil
            return
        }
        guard canPresentDownloadCapsule else {
            pendingCompletion = PendingCompletion(
                success: success,
                error: error,
                successMessageKey: successMessageKey,
                failureMessageKey: failureMessageKey
            )
            return
        }
        if success {
            let message = loc(successMessageKey)
            capsulePresenter?.showDownloadProgress(message, progress: 1)
            let completionPresentationID = capsulePresenter?.presentationID
            scheduleAfter(2) { [weak self] in
                guard let self,
                      !self.isRecording(),
                      let completionPresentationID,
                      self.capsulePresenter?.presentationID == completionPresentationID,
                      self.capsulePresenter?.isShowingDownloadPresentation == true
                else { return }
                self.capsulePresenter?.dismiss(completion: nil)
            }
        } else {
            capsulePresenter?.showError(loc(failureMessageKey, error ?? "Unknown error"), dismissAfter: 6)
        }
    }

    /// session.onRecordingStateChanged 触发时调用。
    func handleRecordingStateChanged(active: Bool) {
        if active { suppressCurrentDownloadPresentation = false }
        guard sherpaDownloadCapsuleActive else { return }
        if active {
            sherpaDownloadDeferredByRecording = true
            capsulePresenter?.dismiss(completion: nil)
        }
    }

    func handleCapsuleDidDismiss(reason: CapsuleDismissReason = .standard) {
        if reason == .recordingResultSubmitted {
            // 结果已提交后给输入框让位；当前下载继续，进度和成功提示不再自动弹回。
            suppressCurrentDownloadPresentation = sherpaDownloadCapsuleActive
            if pendingCompletion?.success == true { pendingCompletion = nil }
        }
        guard capsuleWindow?.isVisible != true else { return }

        if let pendingCompletion, canPresentDownloadCapsule {
            self.pendingCompletion = nil
            finishDownload(
                success: pendingCompletion.success,
                error: pendingCompletion.error,
                successMessageKey: pendingCompletion.successMessageKey,
                failureMessageKey: pendingCompletion.failureMessageKey
            )
            return
        }

        guard sherpaDownloadCapsuleActive,
              !suppressCurrentDownloadPresentation,
              sherpaDownloadDeferredByRecording,
              canPresentDownloadCapsule,
              let message = sherpaDownloadCapsuleMessage else { return }
        updateProgress(progress: sherpaDownloadCapsuleProgress, message: message, force: true)
    }

    private var canPresentDownloadCapsule: Bool {
        if isRecording() { return false }
        if let capsuleWindow,
           capsuleWindow.isVisible,
           !capsuleWindow.isShowingDownloadPresentation {
            return false
        }
        return true
    }
}
