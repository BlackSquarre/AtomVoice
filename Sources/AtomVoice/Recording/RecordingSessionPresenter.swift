import Foundation

protocol PartialTextUpdateScheduledTask: AnyObject {
    func cancel()
}

protocol PartialTextUpdateScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> PartialTextUpdateScheduledTask
}

private final class MainQueuePartialTextUpdateScheduledTask: PartialTextUpdateScheduledTask {
    private var workItem: DispatchWorkItem?

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

private struct MainQueuePartialTextUpdateScheduler: PartialTextUpdateScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> PartialTextUpdateScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return MainQueuePartialTextUpdateScheduledTask(workItem: workItem)
    }
}

/// 录音胶囊 partial 文本节流器：首帧立即显示，窗口期内只保留最新 partial。
/// (Throttle capsule partial-text updates: show the first frame immediately and keep only the latest partial during the cooldown window.)
final class PartialTextUpdateThrottler {
    static let defaultInterval: TimeInterval = 1.0 / 30.0

    private let interval: TimeInterval
    private let scheduler: PartialTextUpdateScheduling
    private var cooldownTask: PartialTextUpdateScheduledTask?
    private var pendingText: String?

    init(
        interval: TimeInterval = PartialTextUpdateThrottler.defaultInterval,
        scheduler: PartialTextUpdateScheduling = MainQueuePartialTextUpdateScheduler()
    ) {
        self.interval = interval
        self.scheduler = scheduler
    }

    func submit(_ text: String, deliver: @escaping (String) -> Void) {
        guard cooldownTask != nil else {
            deliver(text)
            scheduleCooldown(deliver: deliver)
            return
        }
        pendingText = text
    }

    /// 立即冲刷最后一个 pending partial，并重置节流窗口，避免跨状态切换丢最后一帧。
    /// (Flush the last pending partial immediately and reset the throttle window so state transitions do not lose the last frame.)
    func flush(deliver: @escaping (String) -> Void) {
        cooldownTask?.cancel()
        cooldownTask = nil
        guard let pendingText else { return }
        self.pendingText = nil
        deliver(pendingText)
    }

    func cancel() {
        cooldownTask?.cancel()
        cooldownTask = nil
        pendingText = nil
    }

    private func scheduleCooldown(deliver: @escaping (String) -> Void) {
        cooldownTask = scheduler.schedule(after: interval) { [weak self] in
            self?.drain(deliver: deliver)
        }
    }

    private func drain(deliver: @escaping (String) -> Void) {
        cooldownTask = nil
        guard let pendingText else { return }
        self.pendingText = nil
        deliver(pendingText)
        scheduleCooldown(deliver: deliver)
    }
}

enum RecordingSessionPresentationEvent: Equatable {
    case showInitial(compactStatusKey: String?)
    case showRecording
    case showProgress(text: String, hidesWaveform: Bool)
    case showError(message: String, dismissAfter: TimeInterval, ensurePanel: Bool)
    case showRefining
    case updateText(String)
    case updateBands([Float])
    case startShimmer
    case stopShimmer

    static func revealEvents(
        for request: RecordingCapsulePresentationRequest,
        isRecording: Bool,
        compactStatusKey: String?
    ) -> [RecordingSessionPresentationEvent] {
        switch request {
        case .none, .initial:
            return isRecording ? [.showInitial(compactStatusKey: compactStatusKey)] : []
        case .recording:
            return [
                .showInitial(compactStatusKey: compactStatusKey),
                .showRecording,
            ]
        case let .progress(text, hidesWaveform):
            return [.showProgress(text: text, hidesWaveform: hidesWaveform)]
        case let .progressKey(messageKey, hidesWaveform):
            return [.showProgress(text: loc(messageKey), hidesWaveform: hidesWaveform)]
        case let .error(message, dismissAfter):
            return [.showError(message: message, dismissAfter: dismissAfter, ensurePanel: true)]
        case let .errorKey(messageKey, dismissAfter):
            return [.showError(message: loc(messageKey), dismissAfter: dismissAfter, ensurePanel: true)]
        }
    }
}

protocol RecordingSessionPresenting: RecognitionResultPresenting {
    var isShowingError: Bool { get }

    func present(_ event: RecordingSessionPresentationEvent)
    func dismiss(completion: (() -> Void)?)
}

final class RecordingSessionPresenter: RecordingSessionPresenting {
    private let capsuleWindow: CapsuleWindowController
    private let partialTextUpdateThrottler: PartialTextUpdateThrottler

    init(
        capsuleWindow: CapsuleWindowController,
        partialTextUpdateThrottler: PartialTextUpdateThrottler = PartialTextUpdateThrottler()
    ) {
        self.capsuleWindow = capsuleWindow
        self.partialTextUpdateThrottler = partialTextUpdateThrottler
    }

    var isShowingError: Bool {
        capsuleWindow.isShowingError
    }

    func present(_ event: RecordingSessionPresentationEvent) {
        switch event {
        case .updateText(let text):
            ASRLatencyProbe.mark(text, stage: "presenter_update_text")
            partialTextUpdateThrottler.submit(text) { [weak self] latestText in
                self?.capsuleWindow.updateText(latestText)
            }
        case .updateBands(let bands):
            capsuleWindow.updateBands(bands)
        case .startShimmer:
            capsuleWindow.applyShimmerToCapsule()
        case .stopShimmer:
            capsuleWindow.stopShimmer()
        default:
            partialTextUpdateThrottler.flush { [weak self] latestText in
                self?.capsuleWindow.updateText(latestText)
            }
            applyImmediatePresentation(event)
        }
    }

    private func applyImmediatePresentation(_ event: RecordingSessionPresentationEvent) {
        switch event {
        case .showInitial(let compactStatusKey):
            capsuleWindow.show(compactStatusKey: compactStatusKey)
        case .showRecording:
            capsuleWindow.showRecording()
        case let .showProgress(text, hidesWaveform):
            capsuleWindow.showProgress(text, hidesWaveform: hidesWaveform)
        case let .showError(message, dismissAfter, ensurePanel):
            if ensurePanel {
                capsuleWindow.show()
            }
            capsuleWindow.showError(message, dismissAfter: dismissAfter)
        case .showRefining:
            capsuleWindow.showRefining()
        case .updateText, .updateBands, .startShimmer, .stopShimmer:
            break
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        partialTextUpdateThrottler.flush { [weak self] latestText in
            self?.capsuleWindow.updateText(latestText)
        }
        capsuleWindow.dismiss(completion: completion)
    }

    func updateRecognitionText(_ text: String) {
        present(.updateText(text))
    }

    func showRecognitionRefining() {
        present(.showRefining)
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        // 胶囊可能在停止时已提前收起；报错前确保面板存在，避免错误被静默丢弃。
        // (The capsule may have been dismissed early on stop; ensure it exists before showing the error.)
        capsuleWindow.ensureVisible()
        present(.showError(message: message, dismissAfter: dismissAfter, ensurePanel: false))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        dismiss(completion: completion)
    }
}
