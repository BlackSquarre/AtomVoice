import Foundation

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

    init(capsuleWindow: CapsuleWindowController) {
        self.capsuleWindow = capsuleWindow
    }

    var isShowingError: Bool {
        capsuleWindow.isShowingError
    }

    func present(_ event: RecordingSessionPresentationEvent) {
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
        case .updateText(let text):
            capsuleWindow.updateText(text)
        case .updateBands(let bands):
            capsuleWindow.updateBands(bands)
        case .startShimmer:
            capsuleWindow.applyShimmerToCapsule()
        case .stopShimmer:
            capsuleWindow.stopShimmer()
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        capsuleWindow.dismiss(completion: completion)
    }

    func updateRecognitionText(_ text: String) {
        present(.updateText(text))
    }

    func showRecognitionRefining() {
        present(.showRefining)
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        present(.showError(message: message, dismissAfter: dismissAfter, ensurePanel: false))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        dismiss(completion: completion)
    }
}
