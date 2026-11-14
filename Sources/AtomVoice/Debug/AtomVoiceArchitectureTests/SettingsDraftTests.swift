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
            let editor = DoubaoSettingsEditor(readKey: { _ in .value("fixture") }, load: fixture,
                saveKey: { _, _, _ in writes += 1; return true }, persist: { _ in writes += 1 })
            _ = editor.reload()
            try expect(editor.save(editor.baseline!))
            try expect(writes == 0)
        }
        await runner.run("Doubao key failure preserves nonsecret fields and dirty draft") {
            var writes = 0
            let editor = DoubaoSettingsEditor(readKey: { _ in .value("fixture") }, load: fixture,
                saveKey: { _, _, _ in false }, persist: { _ in writes += 1 })
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
            let editor = DoubaoSettingsEditor(readKey: { _ in .failure(-1) }, load: fixture,
                saveKey: { _, _, _ in keyWrites += 1; return false }, persist: { settings.append($0) })
            _ = editor.reload()
            var draft = editor.baseline!
            draft.enableDDC = true
            try expect(editor.save(draft))
            try expect(editor.save(draft))
            try expect(keyWrites == 0 && settings.count == 1)
            try expect(settings[0].enableDDC)
        }
        await runner.run("Doubao service switching keeps keys isolated and cancel writes nothing") {
            var writes = 0
            let editor = DoubaoSettingsEditor(readKey: { service in
                service == .international ? .value("international-fixture") : .value("custom-fixture")
            }, load: fixture, saveKey: { _, _, _ in writes += 1; return true }, persist: { _ in writes += 1 })
            _ = editor.reload()
            var custom = editor.baseline!
            custom.apiKey = "edited-custom"
            custom.endpoint = "wss://fixture.invalid/edited"
            let international = editor.switching(to: .international, from: custom)
            try expect(international.apiKey == "international-fixture")
            try expect(international.endpoint == DoubaoService.international.endpoint)
            let restored = editor.switching(to: .custom, from: international)
            try expect(restored.apiKey == "edited-custom" && restored.endpoint == custom.endpoint)
            try expect(writes == 0)
            _ = editor.reload()
            try expect(editor.baseline?.apiKey == "custom-fixture")
            try expect(editor.baseline?.endpoint == "wss://fixture.invalid")
        }
        await runner.run("Doubao missing international key never inherits China or custom credentials") {
            let editor = DoubaoSettingsEditor(readKey: { $0 == .custom ? .value("custom-fixture") : .notFound }, load: fixture)
            _ = editor.reload()
            let next = editor.switching(to: .international, from: editor.baseline!)
            try expect(next.apiKey.isEmpty)
        }
        await runner.run("Doubao saves service key before activating the selected endpoint") {
            var events: [String] = []
            var saved: VolcengineASRSettings?
            let editor = DoubaoSettingsEditor(readKey: { _ in .notFound }, load: fixture,
                saveKey: { _, service, _ in events.append(service.rawValue); return true },
                persist: { saved = $0; events.append("settings") })
            _ = editor.reload()
            var draft = editor.switching(to: .international, from: editor.baseline!)
            draft.apiKey = "international-fixture"
            try expect(editor.save(draft))
            try expect(events == ["international", "settings"])
            try expect(saved?.selectedService == .international)
            try expect(saved?.trimmedEndpoint == DoubaoService.international.endpoint)
            try expect(!editor.hasChanges(draft))
        }
        await runner.run("Doubao service key failure keeps original active service and supports retry") {
            var fail = true
            var writes = 0
            let editor = DoubaoSettingsEditor(readKey: { _ in .notFound }, load: fixture,
                saveKey: { _, _, _ in !fail }, persist: { _ in writes += 1 })
            _ = editor.reload()
            var draft = editor.switching(to: .international, from: editor.baseline!)
            draft.apiKey = "international-fixture"
            try expect(!editor.save(draft))
            try expect(writes == 0 && editor.baseline?.service == .custom)
            fail = false
            try expect(editor.save(draft))
            try expect(writes == 1 && editor.baseline?.service == .international)
        }
        await runner.run("Doubao saves inactive key drafts and custom address without switching service") {
            var accounts: [DoubaoService] = []
            var saved: VolcengineASRSettings?
            let editor = DoubaoSettingsEditor(readKey: { _ in .notFound }, load: { key in
                var settings = fixture(key)
                settings.endpoint = DoubaoService.china.endpoint!
                return settings
            }, saveKey: { _, service, _ in accounts.append(service); return true }, persist: { saved = $0 },
                loadCustomEndpoint: { "wss://fixture.invalid/original" })
            _ = editor.reload()
            var custom = editor.switching(to: .custom, from: editor.baseline!)
            custom.endpoint = "wss://fixture.invalid/edited"
            custom.apiKey = "custom-fixture"
            let china = editor.switching(to: .china, from: custom)
            try expect(editor.hasChanges(china))
            try expect(editor.save(china))
            try expect(accounts == [.custom])
            try expect(saved?.selectedService == .china)
            try expect(saved?.customEndpoint == custom.endpoint)
            try expect(!editor.hasChanges(china))
        }
        await runner.run("Doubao service selection preserves existing concurrent resource ID") {
            var saved: VolcengineASRSettings?
            let editor = DoubaoSettingsEditor(readKey: { _ in .notFound }, load: { key in
                var settings = fixture(key)
                settings.resourceID = "volc.seedasr.sauc.concurrent"
                return settings
            }, persist: { saved = $0 })
            _ = editor.reload()
            let draft = editor.switching(to: .international, from: editor.baseline!)
            try expect(editor.save(draft))
            try expect(saved?.resourceID == "volc.seedasr.sauc.concurrent")
        }
        await runner.run("Doubao legacy key remains bound to original service after switching and reload") {
            for original in DoubaoService.allCases {
                let backend = InMemorySettingsBackend()
                backend.set(original.endpoint ?? "wss://fixture.invalid", forKey: AppSettings.Keys.doubaoASREndpoint)
                try expect(VolcengineASRSettings.selectedService(backend: backend) == original)
                let oldAccounts = Dictionary(uniqueKeysWithValues: DoubaoService.allCases.map {
                    ($0, VolcengineASRSettings.credentialAccount(for: $0, backend: backend))
                })
                try expect(Set(oldAccounts.values).count == 3)
                try expect(oldAccounts[original] == "apiKey")
                var next = fixture("")
                next.service = .international
                next.persistNonSecretFields(backend: backend)
                try expect(VolcengineASRSettings.selectedService(backend: backend) == .international)
                try expect(backend.string(forKey: AppSettings.Keys.doubaoASREndpoint) == DoubaoService.international.endpoint)
                for service in DoubaoService.allCases {
                    try expect(VolcengineASRSettings.credentialAccount(for: service, backend: backend) == oldAccounts[service])
                }
            }
        }
        await runner.run("Doubao custom mode keeps explicit selection even with an official URL") {
            let backend = InMemorySettingsBackend()
            var settings = fixture("")
            settings.service = .custom
            settings.endpoint = DoubaoService.china.endpoint!
            settings.persistNonSecretFields(backend: backend)
            try expect(VolcengineASRSettings.selectedService(backend: backend) == .custom)
            try expect(backend.string(forKey: AppSettings.Keys.doubaoASRCustomEndpoint) == settings.endpoint)
            try expect(DoubaoService.inferred(from: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream") == .custom)
        }
        await runner.run("Doubao page switches visible address and account link without writing credentials") {
            try await MainActor.run {
                var writes = 0
                let editor = DoubaoSettingsEditor(readKey: { _ in .notFound }, load: fixture,
                    saveKey: { _, _, _ in writes += 1; return true }, persist: { _ in writes += 1 })
                let tab = DoubaoSettingsTab(textFieldDelegate: nil, editor: editor)
                let page = tab.makeView()
                tab.refresh()
                @MainActor func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap(descendants)
                }
                let controls = descendants(page)
                let popup = try require(controls.first { $0.identifier?.rawValue == "doubao.service" } as? NSPopUpButton)
                let endpoint = try require(controls.first { $0.identifier?.rawValue == "doubao.endpoint" } as? NSTextField)
                let link = try require(controls.first { $0.identifier?.rawValue == "doubao.apiKeyLink" } as? NSButton)
                let key = try require(controls.first { $0.identifier?.rawValue == "doubao.apiKey" } as? NSSecureTextField)
                try expect(!endpoint.isHiddenOrHasHiddenAncestor && link.isHidden)
                key.stringValue = "custom-fixture"
                endpoint.stringValue = "wss://fixture.invalid/edited"
                popup.selectItem(at: 1)
                _ = popup.sendAction(try require(popup.action), to: popup.target)
                try expect(endpoint.isHiddenOrHasHiddenAncestor && !link.isHidden)
                try expect(link.toolTip == "https://console.byteplus.com/")
                try expect(key.stringValue.isEmpty)
                popup.selectItem(at: 2)
                _ = popup.sendAction(try require(popup.action), to: popup.target)
                try expect(!endpoint.isHiddenOrHasHiddenAncestor && link.isHidden)
                try expect(endpoint.stringValue == "wss://fixture.invalid/edited")
                try expect(key.stringValue == "custom-fixture")
                try expect(writes == 0)
            }
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
