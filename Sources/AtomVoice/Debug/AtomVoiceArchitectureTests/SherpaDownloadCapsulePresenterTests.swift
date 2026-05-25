import Foundation
@testable import AtomVoiceCore

enum SherpaDownloadCapsulePresenterTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("updateProgress shows download progress when not recording") {
            var currentDate = Date(timeIntervalSince1970: 1)
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { currentDate },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(message: "Downloading", force: false)

            try expect(capsule.events == ["progress:Downloading"])
            currentDate = currentDate.addingTimeInterval(0.3)
            presenter.updateProgress(message: "Downloading 2", force: false)
            try expect(capsule.events == ["progress:Downloading", "progress:Downloading 2"])
        }

        await runner.run("updateProgress throttles within 250ms window") {
            var currentDate = Date(timeIntervalSince1970: 1)
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { currentDate },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(message: "First", force: false)
            currentDate = currentDate.addingTimeInterval(0.1)
            presenter.updateProgress(message: "Second", force: false)

            try expect(capsule.events == ["progress:First"])
        }

        await runner.run("updateProgress shows progress immediately when force=true") {
            let currentDate = Date(timeIntervalSince1970: 1)
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { currentDate },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(message: "First", force: false)
            presenter.updateProgress(message: "Forced", force: true)

            try expect(capsule.events == ["progress:First", "progress:Forced"])
        }

        await runner.run("updateProgress is no-op while recording") {
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { true },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(message: "Hidden", force: true)

            try expect(capsule.events.isEmpty)
        }

        await runner.run("finishDownload shows complete capsule on success and dismisses after 2s") {
            let capsule = FakeDownloadCapsulePresenter()
            var scheduled: [(TimeInterval, () -> Void)] = []
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { delay, action in scheduled.append((delay, action)) }
            )

            presenter.finishDownload(success: true, error: nil)

            try expect(capsule.events == ["update:\(loc("sherpa.download.complete"))"])
            try expect(scheduled.count == 1)
            try expect(scheduled.first?.0 == 2)
            scheduled.first?.1()
            try expect(capsule.events == ["update:\(loc("sherpa.download.complete"))", "dismiss"])
        }

        await runner.run("finishDownload shows error capsule on failure") {
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )

            presenter.finishDownload(success: false, error: "network")

            try expect(capsule.events == ["error:\(loc("sherpa.download.failed", "network")):6.0"])
        }

        await runner.run("finishDownload is no-op while recording") {
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { true },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )

            presenter.finishDownload(success: true, error: nil)

            try expect(capsule.events.isEmpty)
        }

        await runner.run("handleRecordingStateChanged active=true dismisses capsule") {
            var recording = false
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(message: "Downloading", force: true)
            recording = true

            presenter.handleRecordingStateChanged(active: true)

            try expect(capsule.events == ["progress:Downloading", "dismiss"])
        }

        await runner.run("handleRecordingStateChanged active=false re-shows last message if active session was deferred") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(message: "Deferred", force: true)
            recording = false

            presenter.handleRecordingStateChanged(active: false)

            try expect(capsule.events == ["progress:Deferred"])
        }
    }
}

private final class FakeDownloadCapsulePresenter: DownloadCapsulePresenting {
    private(set) var events: [String] = []

    func showDownloadProgress(_ text: String) {
        events.append("progress:\(text)")
    }

    func updateText(_ text: String, completion: (() -> Void)?) {
        events.append("update:\(text)")
        completion?()
    }

    func showError(_ message: String, dismissAfter: TimeInterval) {
        events.append(String(format: "error:%@:%0.1f", message, dismissAfter))
    }

    func dismiss(completion: (() -> Void)?) {
        events.append("dismiss")
        completion?()
    }
}
