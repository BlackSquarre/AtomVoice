import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

final class FakePermissionAccess: PermissionAccessing {
    var statuses: [PermissionKind: PermissionStatus]
    var microphoneRequestResult = true
    var speechRecognitionRequestResult = true
    private(set) var requestedMicrophoneCount = 0
    private(set) var requestedSpeechRecognitionCount = 0
    private(set) var openedSettings: [PermissionKind] = []

    init(statuses: [PermissionKind: PermissionStatus]) {
        self.statuses = statuses
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .denied
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        requestedMicrophoneCount += 1
        completion(microphoneRequestResult)
    }

    func requestSpeechRecognition(completion: @escaping (Bool) -> Void) {
        requestedSpeechRecognitionCount += 1
        completion(speechRecognitionRequestResult)
    }

    func openSettings(for kind: PermissionKind) {
        openedSettings.append(kind)
    }
}

final class FakeTextProcessor: TextPostProcessor {
    let id: String
    private let output: String?
    private(set) var callCount = 0
    private(set) var lastText: String?
    private(set) var lastContext: TextProcessingContext?

    init(id: String, output: String?) {
        self.id = id
        self.output = output
    }

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        callCount += 1
        lastText = text
        lastContext = context
        return output
    }
}

final class FakeRecognitionPresenter: RecognitionResultPresenting {
    private(set) var events: [String] = []

    func updateRecognitionText(_ text: String) {
        events.append("update:\(text)")
    }

    func showRecognitionRefining() {
        events.append("refining")
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        events.append(String(format: "error:%@:%0.1f", message, dismissAfter))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        events.append("dismiss")
        completion?()
    }
}

final class FakeRecognitionRefiner: RecognitionTextRefining {
    var nextProgress: String?
    var nextResult: String?
    var nextError: String?
    private(set) var requests: [String] = []
    var delayCompletion = false
    var pendingCompletion: ((String?, String?) -> Void)?
    var pendingOnProgress: ((String) -> Void)?

    func refine(
        text: String,
        onProgress: ((String) -> Void)?,
        completion: @escaping (String?, String?) -> Void
    ) {
        requests.append(text)
        if delayCompletion {
            pendingCompletion = completion
            pendingOnProgress = onProgress
        } else {
            if let nextProgress {
                onProgress?(nextProgress)
            }
            completion(nextResult, nextError)
        }
    }
}

final class FakeTextOutputSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(
        code: "fake",
        displayNameKey: "fake",
        iconName: "fake",
        supportsStreaming: false
    )
    private(set) var deliveredTexts: [String] = []

    func deliver(text: String, completion: (() -> Void)?) {
        deliveredTexts.append(text)
        completion?()
    }
}

final class FakeTextStreamSession: TextStreamSession {
    private(set) var updates: [String] = []
    private(set) var finalizedReplacements: [String?] = []
    private(set) var cancelCount = 0

    func update(currentText: String) {
        updates.append(currentText)
    }

    func finalize(replacingWith finalText: String?, completion: (() -> Void)?) {
        finalizedReplacements.append(finalText)
        completion?()
    }

    func cancel() {
        cancelCount += 1
    }
}
