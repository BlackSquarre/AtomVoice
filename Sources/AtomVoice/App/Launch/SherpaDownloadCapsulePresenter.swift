import Foundation

protocol DownloadCapsulePresenting: AnyObject {
    func showDownloadProgress(_ text: String)
    func updateText(_ text: String, completion: (() -> Void)?)
    func showError(_ message: String, dismissAfter: TimeInterval)
    func dismiss(completion: (() -> Void)?)
}

extension CapsuleWindowController: DownloadCapsulePresenting {}

final class SherpaDownloadCapsulePresenter {
    private weak var capsulePresenter: (any DownloadCapsulePresenting)?
    private let isRecording: () -> Bool
    private let now: () -> Date
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private var sherpaDownloadCapsuleActive = false
    private var sherpaDownloadCapsuleMessage: String?
    private var sherpaDownloadCapsuleLastUpdate = Date.distantPast

    convenience init(
        capsuleWindow: CapsuleWindowController,
        isRecording: @escaping () -> Bool
    ) {
        self.init(capsulePresenter: capsuleWindow, isRecording: isRecording)
    }

    init(
        capsulePresenter: any DownloadCapsulePresenting,
        isRecording: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() },
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.capsulePresenter = capsulePresenter
        self.isRecording = isRecording
        self.now = now
        self.scheduleAfter = scheduleAfter
    }

    /// 收到下载进度时调用（节流逻辑内部处理，每 250ms 最多刷一次）。
    func updateProgress(message: String, force: Bool) {
        sherpaDownloadCapsuleActive = true
        sherpaDownloadCapsuleMessage = message
        guard !isRecording() else { return }

        let currentTime = now()
        guard force || currentTime.timeIntervalSince(sherpaDownloadCapsuleLastUpdate) >= 0.25 else { return }
        sherpaDownloadCapsuleLastUpdate = currentTime
        capsulePresenter?.showDownloadProgress(message)
    }

    /// 下载结束时调用，决定是否展示完成/失败胶囊。
    func finishDownload(success: Bool, error: String?) {
        sherpaDownloadCapsuleActive = false
        sherpaDownloadCapsuleMessage = nil
        if isRecording() { return }
        if success {
            capsulePresenter?.updateText(loc("sherpa.download.complete"), completion: nil)
            scheduleAfter(2) { [weak self] in
                self?.capsulePresenter?.dismiss(completion: nil)
            }
        } else {
            capsulePresenter?.showError(loc("sherpa.download.failed", error ?? "Unknown error"), dismissAfter: 6)
        }
    }

    /// session.onRecordingStateChanged 触发时调用。
    func handleRecordingStateChanged(active: Bool) {
        guard sherpaDownloadCapsuleActive else { return }
        if active {
            capsulePresenter?.dismiss(completion: nil)
        } else if let message = sherpaDownloadCapsuleMessage {
            updateProgress(message: message, force: true)
        }
    }
}
