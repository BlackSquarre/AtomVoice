import AppKit
import Foundation
@testable import AtomVoiceCore

enum SettingsDraftTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("ASR window commits all edited pages and leaves untouched pages unwritten") {
            let a = DraftPageFake()
            let b = DraftPageFake()
            let untouched = DraftPageFake()
            a.hasChanges = true
            b.hasChanges = true
            b.result = .deferred
            if case .deferred = ASRSettingsCommitter.save([a, b, untouched]) {} else {
                throw TestFailure(file: #filePath, line: #line, message: "Expected deferred save")
            }
            try expect(a.saveCount == 1 && b.saveCount == 1 && untouched.saveCount == 0)
            _ = ASRSettingsCommitter.save([a, b, untouched])
            try expect(a.saveCount == 1)
        }
        await runner.run("ASR window stops on failed credential commit without claiming success") {
            let a = DraftPageFake()
            let b = DraftPageFake()
            a.hasChanges = true
            b.hasChanges = true
            a.result = .failed(message: "fixture", color: .systemRed)
            if case .failed = ASRSettingsCommitter.save([a, b]) {} else {
                throw TestFailure(file: #filePath, line: #line, message: "Expected failed save")
            }
            try expect(b.saveCount == 0 && a.hasChanges)
        }
        await runner.run("Doubao unchanged form does not save key or nonsecret settings") {
            var writes = 0
            let editor = DoubaoSettingsEditor(readKey: { .value("fixture") }, load: fixture,
                saveKey: { _, _ in writes += 1; return true }, persist: { _ in writes += 1 })
            _ = editor.reload()
            try expect(editor.save(editor.baseline!))
            try expect(writes == 0)
        }
        await runner.run("Doubao key failure preserves nonsecret fields and dirty draft") {
            var writes = 0
            let editor = DoubaoSettingsEditor(readKey: { .value("fixture") }, load: fixture,
                saveKey: { _, _ in false }, persist: { _ in writes += 1 })
            _ = editor.reload()
            var draft = editor.baseline!
            draft.apiKey = "replacement"
            draft.endpoint = "wss://fixture.invalid/new"
            try expect(!editor.save(draft))
            try expect(writes == 0)
            try expect(editor.hasChanges(draft))
            try expect(editor.baseline?.apiKey == "fixture")
        }
        await runner.run("Doubao nonsecret edit preserves unreadable unedited key and commits once") {
            var keyWrites = 0
            var settings: [VolcengineASRSettings] = []
            let editor = DoubaoSettingsEditor(readKey: { .failure(-1) }, load: fixture,
                saveKey: { _, _ in keyWrites += 1; return false }, persist: { settings.append($0) })
            _ = editor.reload()
            var draft = editor.baseline!
            draft.enableDDC = true
            try expect(editor.save(draft))
            try expect(editor.save(draft))
            try expect(keyWrites == 0 && settings.count == 1)
            try expect(settings[0].enableDDC)
        }
        await runner.run("Provider store uses supplied backend without UI dependency") {
            let backend = InMemorySettingsBackend()
            ProviderStore.save([.init(name: "fixture", baseURL: "https://fixture.invalid", defaultModel: "model")], backend: backend)
            let providers = ProviderStore.load(backend: backend)
            try expect(providers.count == 1 && providers[0].name == "fixture")
        }
    }
    private static func fixture(_ key: String) -> VolcengineASRSettings {
        .init(endpoint: "wss://fixture.invalid", apiKey: key, resourceID: DoubaoModelKind.v2.resourceID,
              enableITN: true, enableDDC: false, enableNonstream: false, selectedLanguage: "en-US")
    }
}

private final class DraftPageFake: ASRSettingsTab {
    let identifier = "fixture"
    let label = "fixture"
    var hasChanges = false
    var saveCount = 0
    var result = ASRSettingsTabSaveOutcome.saved
    func makeView() -> NSView { NSView() }
    func refresh() {}
    func save() -> ASRSettingsTabSaveOutcome {
        saveCount += 1
        if case .saved = result { hasChanges = false }
        return result
    }
}
