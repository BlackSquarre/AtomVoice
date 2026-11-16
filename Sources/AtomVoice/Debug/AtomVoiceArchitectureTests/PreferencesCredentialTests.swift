import AppKit
import Foundation
@testable import AtomVoiceCore

enum PreferencesCredentialTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("OpenAI asynchronous credentials leave the page responsive and perform only one read") {
            try await openAILoad()
        }
        await runner.run("OpenAI metadata remains available while a credential transaction waits") {
            try await openAIMetadata()
        }
        await runner.run("OpenAI asynchronous save rejects duplicate submission and retains a failed draft") {
            try await openAISave()
        }
        await runner.run("Doubao asynchronous service switching preserves drafts and failed saves retain configuration") {
            try await doubaoDraft()
        }
        await runner.run("Doubao asynchronous credential read failure is visible and leaves fields editable") {
            try await doubaoReadFailure()
        }
    }

    @MainActor
    private static func openAILoad() async throws {
        let gate = CredentialOperationGate()
        defer { gate.release() }
        let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: {
            gate.wait()
            return .failure(-1)
        }, writeKey: { _ in false }, deleteKey: { false })
        let editor = OpenAIASRSettingsEditor(settings: settings)
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: editor, allowsExternalActions: false,
                                   usesAsyncCredentials: true, loadModels: { _ in [] })
        let view = tab.makeView(includeContext: false, allowsModelFetch: false)
        tab.refresh()
        tab.refresh()
        try expect(tab.isLoadingCredentials && editor.baseline == nil)
        let key: NSSecureTextField = try control("openai.apiKey", in: view)
        try expect(!key.isEnabled)
        try await waitUntil { gate.calls == 1 }
        gate.release()
        try await waitUntil { !tab.isLoadingCredentials }
        try expect(key.isEnabled && editor.baseline != nil && gate.calls == 1)
        if case .failure = editor.keyReadResult {} else {
            throw TestFailure(file: #filePath, line: #line, message: "Read failure must not become an absent key")
        }
    }

    @MainActor
    private static func openAIMetadata() async throws {
        let gate = CredentialOperationGate()
        defer { gate.release() }
        let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: {
            gate.wait()
            return .notFound
        })
        DispatchQueue.global(qos: .userInitiated).async { _ = settings.apiKeyReadResult() }
        try await waitUntil { gate.calls == 1 }
        let started = ProcessInfo.processInfo.systemUptime
        _ = try settings.configuration()
        settings.privacyAccepted = true
        try expect(settings.privacyAccepted)
        try expect(ProcessInfo.processInfo.systemUptime - started < 0.5,
                   "Metadata must not wait for the intentionally blocked credential read")
    }

    @MainActor
    private static func openAISave() async throws {
        let gate = CredentialOperationGate()
        defer { gate.release() }
        let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .value("fixture") }, writeKey: { _ in
            gate.wait()
            return false
        }, deleteKey: { false })
        let editor = OpenAIASRSettingsEditor(settings: settings)
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: editor, allowsExternalActions: false,
                                   usesAsyncCredentials: true, loadModels: { _ in [] })
        let view = tab.makeView(includeContext: false, allowsModelFetch: false)
        tab.refresh()
        try await waitUntil { !tab.isLoadingCredentials }
        let key: NSSecureTextField = try control("openai.apiKey", in: view)
        let language: NSTextField = try control("openai.languages", in: view)
        key.stringValue = "replacement-fixture"
        language.stringValue = "en"
        var failed = false
        tab.onOperationCompleted = { _, result in if case .failed = result { failed = true } }
        if case .deferred = tab.save() {} else { try expect(false, "Expected asynchronous save") }
        _ = tab.save()
        try expect(tab.isSavingCredentials && !key.isEnabled)
        try await waitUntil { gate.calls == 1 }
        gate.release()
        try await waitUntil { !tab.isSavingCredentials }
        try expect(failed && gate.calls == 1 && tab.hasChanges)
        try expect(key.stringValue == "replacement-fixture" && key.isEnabled)
        let configuration = try settings.configuration()
        try expect(configuration.languages.isEmpty)
    }

    @MainActor
    private static func doubaoDraft() async throws {
        let editor = DoubaoSettingsEditor(readKey: { service in .value("fixture-" + service.rawValue) }, load: { key in
            .init(endpoint: VolcengineASRSettings.defaultEndpoint, apiKey: key,
                  resourceID: DoubaoModelKind.v2.resourceID, enableITN: true,
                  enableDDC: false, enableNonstream: false, selectedLanguage: "en-US")
        }, saveKey: { _, _, _ in false }, persist: { _ in
            assertionFailure("A failed credential save must not commit configuration")
        }, loadCustomEndpoint: { "wss://fixture.invalid" })
        let loaded = await withCheckedContinuation { continuation in editor.reloadAsync { continuation.resume(returning: $0) } }
        let baseline = DoubaoSettingsDraft(settings: loaded)
        var changed = baseline
        changed.apiKey = "new-fixture"
        let custom = await withCheckedContinuation { continuation in
            editor.switchAsync(to: .custom, from: changed) { continuation.resume(returning: $0) }
        }
        let returned = await withCheckedContinuation { continuation in
            editor.switchAsync(to: baseline.service, from: custom) { continuation.resume(returning: $0) }
        }
        try expect(returned.apiKey == "new-fixture")
        let saved = await withCheckedContinuation { continuation in editor.saveAsync(returned) { continuation.resume(returning: $0) } }
        try expect(!saved && editor.baseline == baseline && editor.hasChanges(returned))
    }

    @MainActor
    private static func doubaoReadFailure() async throws {
        let editor = DoubaoSettingsEditor(readKey: { _ in .failure(-1) }, load: { key in
            .init(endpoint: VolcengineASRSettings.defaultEndpoint, apiKey: key,
                  resourceID: DoubaoModelKind.v2.resourceID, enableITN: true,
                  enableDDC: false, enableNonstream: false, selectedLanguage: "en-US")
        }, saveKey: { _, _, _ in false }, persist: { _ in }, loadCustomEndpoint: { "wss://fixture.invalid" })
        let tab = DoubaoSettingsTab(textFieldDelegate: nil, editor: editor, usesAsyncCredentials: true)
        let view = tab.makeView()
        tab.refresh()
        try expect(tab.isBusy)
        try await waitUntil { !tab.isBusy }
        let status: NSTextField = try control("doubao.keyStatus", in: view)
        let key: NSSecureTextField = try control("doubao.apiKey", in: view)
        try expect(status.stringValue == loc("doubao.settings.keychainFailed"))
        try expect(key.isEnabled && key.stringValue.isEmpty && !tab.hasChanges)
    }

    @MainActor
    private static func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        if view.identifier?.rawValue == identifier, let match = view as? T { return match }
        for child in view.subviews {
            if let found: T = try? control(identifier, in: child) { return found }
        }
        throw TestFailure(file: #filePath, line: #line, message: "Missing control: " + identifier)
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TestFailure(file: #filePath, line: #line, message: "Credential operation timed out")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class CredentialOperationGate {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func wait() {
        lock.lock(); count += 1; lock.unlock()
        _ = semaphore.wait(timeout: .now() + 2)
    }
    func release() { semaphore.signal() }
}
