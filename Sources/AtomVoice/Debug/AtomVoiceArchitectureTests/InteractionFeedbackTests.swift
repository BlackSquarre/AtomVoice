import AppKit
import Foundation
@testable import AtomVoiceCore

enum InteractionFeedbackTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("OOBE headphone card text, checkbox, Space and accessibility toggle once") {
            try await MainActor.run {
                let card = OOBEHeadphoneControlCardView(frame: NSRect(x: 0, y: 0, width: 280, height: 270))
                card.setEnabled(false)
                card.layoutSubtreeIfNeeded()
                var changes: [Bool] = []
                card.onToggle = { changes.append($0) }
                let checkbox = try require(descendants(card).compactMap { $0 as? NSButton }.first)
                let text = try require(descendants(card).compactMap { $0 as? NSTextField }.first)
                let textPoint = text.convert(NSPoint(x: text.bounds.midX, y: text.bounds.midY), to: card)
                let checkboxPoint = checkbox.convert(NSPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY), to: card)
                try expect(card.hitTest(textPoint) === card, "Card text must share the card action")
                try expect(card.hitTest(checkboxPoint) === checkbox, "Checkbox must keep its own single click target")
                checkbox.performClick(nil)
                try expect(changes == [true])
                try expect((card.accessibilityValue() as? Bool) == true)

                let space = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49))
                card.keyDown(with: space)
                try expect(changes == [true, false])
                let repeatSpace = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: true, keyCode: 49))
                card.keyDown(with: repeatSpace)
                try expect(changes.count == 2, "Holding Space must not repeatedly flip the selection")
                try expect(card.accessibilityPerformPress())
                try expect(changes == [true, false, true] && checkbox.state == .on)

                let click = try require(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 4, y: 4),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 0))
                card.mouseUp(with: click)
                try expect(changes == [true, false, true, false] && checkbox.state == .off)
                try expect(card.acceptsFirstResponder && checkbox.refusesFirstResponder)
            }
        }

        await runner.run("Manual update check gives immediate feedback and repeated clicks share its request") {
            let source = FeedbackReleaseSource()
            let presenter = FeedbackUpdatePresenter()
            let checker = makeChecker(source, presenter)
            checker.checkForUpdates()
            try expect(checker.state == .checking && presenter.events == ["show"])
            checker.checkForUpdates()
            try expect(source.fetches == 1 && presenter.events == ["show", "front"])
            source.finish(.failure(URLError(.notConnectedToInternet)))
            try await waitUntil { checker.state == .idle }
            try expect(presenter.events == ["show", "front", "close", "alert"])
        }

        await runner.run("Silent update check becomes visible once when user requests its result") {
            let source = FeedbackReleaseSource()
            let presenter = FeedbackUpdatePresenter()
            let checker = makeChecker(source, presenter)
            checker.checkForUpdates(silent: true)
            try expect(presenter.events.isEmpty)
            checker.checkForUpdates()
            checker.checkForUpdates()
            try expect(source.fetches == 1 && presenter.events == ["show", "front", "front"])
            source.finish(.success(release(version: "1.0.0")))
            try await waitUntil { checker.state == .idle }
            try expect(presenter.events == ["show", "front", "front", "close", "alert"])
        }

        await runner.run("Silent completed update check does not create or close user progress") {
            let source = FeedbackReleaseSource()
            let presenter = FeedbackUpdatePresenter()
            let checker = makeChecker(source, presenter)
            checker.checkForUpdates(silent: true)
            source.finish(.success(release(version: "1.0.0")))
            try await waitUntil { checker.state == .idle }
            try expect(presenter.events.isEmpty)
        }

        await runner.run("Update check feedback closes before a declined release prompt") {
            let source = FeedbackReleaseSource()
            let presenter = FeedbackUpdatePresenter()
            let checker = makeChecker(source, presenter)
            checker.checkForUpdates()
            source.finish(.success(release(version: "2.0.0")))
            try await waitUntil { checker.state == .idle }
            try expect(presenter.events == ["show", "close", "confirm"])
            try expect(source.downloads == 0)
        }

        await runner.run("Update download failure closes download progress after checking progress") {
            let source = FeedbackReleaseSource()
            let presenter = FeedbackUpdatePresenter()
            presenter.acceptDownload = true
            let checker = makeChecker(source, presenter)
            checker.checkForUpdates()
            source.finish(.success(release(version: "2.0.0")))
            try await waitUntil { checker.state == .idle }
            try expect(presenter.events == ["show", "close", "confirm", "show", "close", "alert"])
            try expect(source.downloads == 1)
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func makeChecker(_ source: FeedbackReleaseSource, _ presenter: FeedbackUpdatePresenter) -> UpdateChecker {
        UpdateChecker(releaseSource: source, installer: FeedbackUpdateInstaller(), presenter: presenter,
                      currentVersion: { "1.0.0" }, currentBundlePath: { "/fixture/AtomVoice.app" })
    }

    private static func release(version: String) -> ReleaseInfo {
        ReleaseInfo(version: version, downloadURL: URL(string: "https://fixture.invalid/update.zip")!,
                    assetName: "update.zip", checksumsURL: URL(string: "https://fixture.invalid/checksums")!,
                    isPreRelease: false, isDebugBuild: false)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try expect(predicate(), "Timed out waiting for offline update feedback")
    }
}

private final class FeedbackReleaseSource: ReleaseSource {
    var fetches = 0
    var downloads = 0
    private var completion: ((Result<ReleaseInfo, Error>) -> Void)?

    func fetchLatestRelease(includeBeta: Bool, preferDebugBuild: Bool,
                            completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        fetches += 1
        self.completion = completion
    }

    func finish(_ result: Result<ReleaseInfo, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }

    func downloadAsset(_ release: ReleaseInfo, completion: @escaping (Result<OwnedUpdateArtifact, Error>) -> Void) {
        downloads += 1
        completion(.failure(URLError(.notConnectedToInternet)))
    }

    func fetchChecksumsListing(for release: ReleaseInfo, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(URLError(.notConnectedToInternet)))
    }
}

private final class FeedbackUpdatePresenter: UpdatePresenting {
    var events: [String] = []
    var acceptDownload = false
    func confirmDownload(version: String, currentVersion: String, isPreRelease: Bool, isDebugBuild: Bool, summary: String?) -> Bool {
        events.append("confirm")
        return acceptDownload
    }
    func confirmRestart(version: String) -> Bool { false }
    func showProgress(_ message: String) { events.append("show") }
    func updateProgressLabel(_ message: String) {}
    func closeProgress() { events.append("close") }
    func bringProgressToFront() { events.append("front") }
    func showAlert(title: String, message: String) { events.append("alert") }
    func terminateApplication() {}
}

private final class FeedbackUpdateInstaller: UpdateInstaller {
    func verifyChecksum(zipURL: URL, listing: String, assetName: String) throws { throw URLError(.unsupportedURL) }
    func extractZip(_ zipURL: URL) throws -> OwnedUpdateArtifact { throw URLError(.unsupportedURL) }
    func validateDownloadedApp(_ appURL: URL, currentVersion: String, expectedVersion: String) throws { throw URLError(.unsupportedURL) }
    func applyAndRelaunch(newAppURL: URL, currentBundlePath: String) throws { throw URLError(.unsupportedURL) }
}
