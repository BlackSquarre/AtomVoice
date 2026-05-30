import Cocoa
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

            presenter.updateProgress(progress: 0.1, message: "Downloading", force: false)

            try expect(capsule.events == ["progress:0.10:Downloading"])
            currentDate = currentDate.addingTimeInterval(0.3)
            presenter.updateProgress(progress: 0.2, message: "Downloading 2", force: false)
            try expect(capsule.events == ["progress:0.10:Downloading", "progress:0.20:Downloading 2"])
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

            presenter.updateProgress(progress: 0.1, message: "First", force: false)
            currentDate = currentDate.addingTimeInterval(0.1)
            presenter.updateProgress(progress: 0.2, message: "Second", force: false)

            try expect(capsule.events == ["progress:0.10:First"])
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

            presenter.updateProgress(progress: 0.1, message: "First", force: false)
            presenter.updateProgress(progress: 0.2, message: "Forced", force: true)

            try expect(capsule.events == ["progress:0.10:First", "progress:0.20:Forced"])
        }

        await runner.run("updateProgress is no-op while recording") {
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { true },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(progress: 0.1, message: "Hidden", force: true)

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
            presenter.updateProgress(progress: 0.4, message: "Downloading", force: true)
            recording = true

            presenter.handleRecordingStateChanged(active: true)

            try expect(capsule.events == ["progress:0.40:Downloading", "dismiss"])
        }

        await runner.run("download progress resumes after capsule dismiss finishes") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let window = CapsuleWindowController()
            window.panel = NSPanel()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                capsuleWindow: window,
                isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(progress: 0.6, message: "Deferred", force: true)
            presenter.handleRecordingStateChanged(active: true)
            recording = false

            presenter.handleRecordingStateChanged(active: false)
            try expect(capsule.events == ["dismiss"])

            window.panel = nil
            window.onDidDismiss?()

            try expect(capsule.events == ["dismiss", "progress:0.60:Deferred"])
        }

        await runner.run("download progress does not steal non-download capsule after recording") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let window = CapsuleWindowController()
            window.panel = NSPanel()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                capsuleWindow: window,
                isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, _ in }
            )

            presenter.updateProgress(progress: 0.7, message: "Deferred", force: true)
            presenter.handleRecordingStateChanged(active: true)
            recording = false
            presenter.handleRecordingStateChanged(active: false)

            try expect(capsule.events == ["dismiss"])

            // 模拟识别结果胶囊仍在，占用同一个 window。
            window.onDidDismiss?()

            try expect(capsule.events == ["dismiss"])
        }
    }
}

private final class FakeDownloadCapsulePresenter: DownloadCapsulePresenting {
    private(set) var events: [String] = []

    func showDownloadProgress(_ text: String, progress: Double) {
        events.append(String(format: "progress:%0.2f:%@", progress, text))
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
