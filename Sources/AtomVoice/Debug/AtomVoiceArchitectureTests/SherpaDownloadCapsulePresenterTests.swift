import Cocoa
import Foundation
@testable import AtomVoiceCore

enum SherpaDownloadCapsulePresenterTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Recording result submission suppresses current download progress and successful completion") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule, isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) }, scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(progress: 0.2, message: "Deferred", force: true)
            recording = false
            presenter.handleCapsuleDidDismiss(reason: .recordingResultSubmitted)
            presenter.updateProgress(progress: 0.7, message: "Still downloading", force: false)
            presenter.handleCapsuleDidDismiss()
            presenter.finishDownload(success: true, error: nil)
            try expect(capsule.events.isEmpty)

            presenter.updateProgress(progress: 0.1, message: "Next download", force: true)
            try expect(capsule.events == ["progress:0.10:Next download"])
        }
        await runner.run("Explicit download presentation can resume after successful recording hide") {
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule, isRecording: { false },
                now: { Date(timeIntervalSince1970: 1) }, scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(progress: 0.1, message: "Started", force: true)
            presenter.handleCapsuleDidDismiss(reason: .recordingResultSubmitted)
            presenter.updateProgress(progress: 0.2, message: "Hidden", force: false)
            presenter.updateProgress(progress: 0.3, message: "Requested", force: true)
            try expect(capsule.events == ["progress:0.10:Started", "progress:0.30:Requested"])
        }
        await runner.run("Suppressed download still reports errors and does not block later downloads") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule, isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) }, scheduleAfter: { _, _ in }
            )
            presenter.updateProgress(progress: 0.1, message: "Deferred", force: true)
            recording = false
            presenter.handleCapsuleDidDismiss(reason: .recordingResultSubmitted)
            presenter.finishDownload(success: false, error: "network")
            try expect(capsule.events == ["error:\(loc("sherpa.download.failed", "network")):6.0"])
            presenter.updateProgress(progress: 0.1, message: "Next", force: true)
            try expect(capsule.events.last == "progress:0.10:Next")
        }
        await runner.run("A pending download success does not reopen after recording result submission") {
            var recording = true
            let capsule = FakeDownloadCapsulePresenter()
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule, isRecording: { recording },
                now: { Date(timeIntervalSince1970: 1) }, scheduleAfter: { _, _ in }
            )
            presenter.finishDownload(success: true, error: nil)
            recording = false
            presenter.handleCapsuleDidDismiss(reason: .recordingResultSubmitted)
            presenter.handleCapsuleDidDismiss()
            try expect(capsule.events.isEmpty)
        }
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

            try expect(capsule.events == ["progress:1.00:\(loc("sherpa.download.complete"))"])
            try expect(scheduled.count == 1)
            try expect(scheduled.first?.0 == 2)
            scheduled.first?.1()
            try expect(capsule.events == ["progress:1.00:\(loc("sherpa.download.complete"))", "dismiss"])
        }

        await runner.run("download completion dismiss does not close a newer presentation") {
            let capsule = FakeDownloadCapsulePresenter()
            var scheduled: [() -> Void] = []
            let presenter = SherpaDownloadCapsulePresenter(
                capsulePresenter: capsule,
                isRecording: { false },
                now: { Date(timeIntervalSince1970: 1) },
                scheduleAfter: { _, action in scheduled.append(action) }
            )

            presenter.finishDownload(success: true, error: nil)
            capsule.showNewRecordingPresentation()
            scheduled.first?()

            try expect(!capsule.events.contains("dismiss"))
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
            window.onDidDismiss?(.standard)

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
            window.onDidDismiss?(.standard)

            try expect(capsule.events == ["dismiss"])
        }
    }
}

private final class FakeDownloadCapsulePresenter: DownloadCapsulePresenting {
    private(set) var events: [String] = []
    private(set) var presentationID = 0
    private(set) var isShowingDownloadPresentation = false

    func showDownloadProgress(_ text: String, progress: Double) {
        if !isShowingDownloadPresentation {
            presentationID += 1
        }
        isShowingDownloadPresentation = true
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
        isShowingDownloadPresentation = false
        events.append("dismiss")
        completion?()
    }

    func showNewRecordingPresentation() {
        presentationID += 1
        isShowingDownloadPresentation = false
        events.append("recording")
    }
}
