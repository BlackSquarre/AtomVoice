import AppKit
import Foundation
@testable import AtomVoiceCore

enum OpenAISettingsTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("OpenAI legacy configuration keeps the live model without a dirty default selection") {
            let legacy = Data(#"{"schemaVersion":1,"languages":["zh-cn","en"],"prompt":"fixture context","keywords":["term"]}"#.utf8)
            let backend = InMemorySettingsBackend()
            backend.set(legacy, forKey: AppSettings.Keys.openaiASRConfiguration)
            let settings = OpenAIASRSettings(backend: backend, readKey: { .notFound }, writeKey: { _ in false }, deleteKey: { false })
            let editor = OpenAIASRSettingsEditor(settings: settings)
            var draft = editor.reload()
            try expect(draft.configuration.model == nil && draft.configuration.resolvedModel == .live)
            try expect(draft.configuration.languages == ["zh-cn", "en"] && draft.configuration.delay == nil)
            try expect(OpenAIASRModel.live.supportsContext && OpenAIASRModel.live.supportsMultipleLanguages)
            try expect(!OpenAIASRModel.whisper.supportsContext && !OpenAIASRModel.whisper.supportsMultipleLanguages)
            draft.configuration.model = .live
            try expect(!editor.hasChanges(draft))
            let normalized = try draft.configuration.validated()
            try expect(normalized.model == nil && normalized.prompt == "fixture context" && normalized.keywords == ["term"])
        }
        await runner.run("OpenAI Whisper maps supported languages to a single ISO language") {
            for language in ["zh", "zh-cn", "zh-tw", "zh-hk", "cmn"] {
                var configuration = OpenAIASRConfiguration(model: .whisper)
                configuration.languages = [language]
                let normalized = try configuration.validated()
                try expect(normalized.languages == ["zh"] && normalized.resolvedModel == .whisper)
            }
            for language in ["en", "ja", "ko", "es", "fr", "de"] {
                let normalized = try OpenAIASRConfiguration(model: .whisper, languages: [language]).validated()
                try expect(normalized.languages == [language])
            }
            for selectedLanguage in ["zh-CN", "zh-TW"] {
                let normalized = try OpenAIASRConfiguration(model: .whisper).validated(selectedLanguage: selectedLanguage)
                try expect(normalized.languages == ["zh"])
            }
            let unselected = try OpenAIASRConfiguration(model: .whisper).validated()
            try expect(unselected.languages.isEmpty)
            let duplicates = try OpenAIASRConfiguration(model: .whisper, languages: ["zh-cn", "zh-tw", "cmn"]).validated()
            try expect(duplicates.languages == ["zh"])
        }
        await runner.run("OpenAI Whisper rejects unsupported and multiple languages before credential mutation") {
            let backend = InMemorySettingsBackend()
            var writes = 0
            let settings = OpenAIASRSettings(backend: backend, readKey: { .notFound }, writeKey: { _ in writes += 1; return true }, deleteKey: { true })
            for languages in [["yue"], ["zh-cn", "en"], ["es", "fr"]] {
                let configuration = OpenAIASRConfiguration(model: .whisper, languages: languages)
                do { try settings.save(configuration, keyEdit: .replace("fixture"), previousKeyRead: .notFound); throw TestFailure(file: #filePath, line: #line, message: "Expected unsupported Whisper language") }
                catch OpenAIASRSettingsError.invalidConfiguration {}
            }
            try expect(writes == 0 && backend.data(forKey: AppSettings.Keys.openaiASRConfiguration) == nil)
            let live = try OpenAIASRConfiguration(languages: ["yue", "zh-cn", "en"]).validated()
            try expect(live.languages == ["yue", "zh-cn", "en"])
        }
        await runner.run("OpenAI selected model persists while an earlier runtime snapshot remains frozen") {
            let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .value("fixture") }, writeKey: { _ in true }, deleteKey: { true })
            let earlier = try settings.snapshot(selectedLanguage: "zh-TW")
            let next = OpenAIASRConfiguration(model: .whisper, delay: "low", languages: ["zh-tw"], prompt: "fixture context", keywords: ["term"])
            try settings.save(next, keyEdit: .unchanged, previousKeyRead: .value("fixture"))
            let saved = try settings.configuration()
            let current = try settings.snapshot(selectedLanguage: "en-US")
            try expect(saved.model == .whisper && saved.languages == ["zh"])
            try expect(current.configuration == saved && current.configuration.delay == "low")
            try expect(current.configuration.prompt == "fixture context" && current.configuration.keywords == ["term"])
            try expect(earlier.configuration.resolvedModel == .live && earlier.configuration.languages == ["zh-tw"])
            let encoded = try JSONEncoder().encode(saved)
            let decoded = try JSONDecoder().decode(OpenAIASRConfiguration.self, from: encoded)
            try expect(decoded == saved)
        }
        await runner.run("OpenAI snapshot reads its key once and maps the current recognition language") {
            let backend = InMemorySettingsBackend()
            var reads = 0
            let settings = OpenAIASRSettings(backend: backend, readKey: { reads += 1; return .value(" fixture ") }, writeKey: { _ in false }, deleteKey: { false })
            let first = try settings.snapshot(selectedLanguage: "zh-TW")
            try expect(reads == 1 && first.apiKey == "fixture")
            try expect(first.configuration.languages == ["zh-tw"])
            try expect(!settings.privacyAccepted)
        }
        await runner.run("OpenAI config save does not overwrite consent accepted after a draft opened") {
            let backend = InMemorySettingsBackend()
            let settings = OpenAIASRSettings(backend: backend, readKey: { .notFound }, writeKey: { _ in true }, deleteKey: { true })
            let editor = OpenAIASRSettingsEditor(settings: settings)
            var draft = editor.reload()
            settings.privacyAccepted = true
            draft.configuration.prompt = "fixture context"
            try editor.save(draft)
            try expect(settings.privacyAccepted)
            let saved = try settings.configuration()
            try expect(saved.prompt == "fixture context")
            try expect(!editor.hasChanges(.init(configuration: draft.configuration)))
        }
        await runner.run("OpenAI nonsecret edits preserve an unreadable unedited key") {
            let backend = InMemorySettingsBackend()
            var writes = 0
            let settings = OpenAIASRSettings(backend: backend, readKey: { .failure(-1) }, writeKey: { _ in writes += 1; return false }, deleteKey: { writes += 1; return false })
            let editor = OpenAIASRSettingsEditor(settings: settings)
            var draft = editor.reload()
            draft.configuration.keywords = ["term", "term", ""]
            try editor.save(draft)
            try expect(writes == 0)
            let saved = try settings.configuration()
            try expect(saved.keywords == ["term"])
        }
        await runner.run("OpenAI key write failure preserves configuration and dirty draft") {
            let backend = InMemorySettingsBackend()
            let settings = OpenAIASRSettings(backend: backend, readKey: { .value("fixture") }, writeKey: { _ in false }, deleteKey: { false })
            let editor = OpenAIASRSettingsEditor(settings: settings)
            var draft = editor.reload()
            draft.keyEdit = .replace("replacement")
            draft.configuration.prompt = "new context"
            do { try editor.save(draft); throw TestFailure(file: #filePath, line: #line, message: "Expected key failure") }
            catch OpenAIASRSettingsError.keychainUnavailable {}
            let saved = try settings.configuration()
            try expect(saved.prompt.isEmpty)
            try expect(editor.hasChanges(draft))
        }
        await runner.run("OpenAI invalid configuration cannot write credentials or replace stored data") {
            let backend = InMemorySettingsBackend()
            var writes = 0
            let settings = OpenAIASRSettings(backend: backend, readKey: { .notFound }, writeKey: { _ in writes += 1; return true }, deleteKey: { true })
            var value = OpenAIASRConfiguration()
            value.keywords = ["invalid\nterm"]
            do { try settings.save(value, keyEdit: .replace("fixture"), previousKeyRead: .notFound); throw TestFailure(file: #filePath, line: #line, message: "Expected invalid config") }
            catch OpenAIASRSettingsError.invalidConfiguration {}
            try expect(writes == 0)
            try expect(backend.data(forKey: AppSettings.Keys.openaiASRConfiguration) == nil)
        }
        await runner.run("OpenAI explicit clear does not delete a key whose read failed") {
            var deletes = 0
            let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .failure(-1) }, writeKey: { _ in false }, deleteKey: { deletes += 1; return true })
            do { try settings.save(.init(), keyEdit: .clear, previousKeyRead: .failure(-1)); throw TestFailure(file: #filePath, line: #line, message: "Expected unreadable key protection") }
            catch OpenAIASRSettingsError.keychainUnavailable {}
            try expect(deletes == 0)
        }
        await runner.run("OpenAI configuration snapshots remain unchanged after the next settings save") {
            let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .value("fixture") }, writeKey: { _ in true }, deleteKey: { true })
            let old = try settings.snapshot(selectedLanguage: "en-US")
            var next = OpenAIASRConfiguration()
            next.languages = ["zh-cn", "en", "en"]
            next.prompt = "new context"
            try settings.save(next, keyEdit: .unchanged, previousKeyRead: .value("fixture"))
            let current = try settings.snapshot(selectedLanguage: "en-US")
            try expect(old.configuration.prompt.isEmpty && old.configuration.languages == ["en"])
            try expect(current.configuration.prompt == "new context" && current.configuration.languages == ["zh-cn", "en"])
        }
        await runner.run("OpenAI missing and inaccessible credentials remain distinct") {
            for result in [KeychainStringReadResult.notFound, .failure(-1)] {
                let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { result }, writeKey: { _ in false }, deleteKey: { false })
                do { _ = try settings.snapshot(selectedLanguage: "en-US"); throw TestFailure(file: #filePath, line: #line, message: "Expected key error") }
                catch OpenAIASRSettingsError.missingKey { try expect(result == .notFound) }
                catch OpenAIASRSettingsError.keychainUnavailable { try expect(result == .failure(-1)) }
            }
        }
        await runner.run("OpenAI primary permissions and Apple recovery are separate") {
            let requirements = PermissionRequirements.forEngine(OpenAIASRSettings.engineCode)
            try expect(requirements.primary == [.accessibility, .microphone])
            try expect(requirements.recovery == [.speechRecognition])
            try expect(PermissionRequirements.startupRequests == [.microphone, .speechRecognition])
        }
        await runner.run("OpenAI tab leaves a saved key unexposed and edits without writes") {
            try await MainActor.run {
                var writes = 0
                let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .value("fixture") }, writeKey: { _ in writes += 1; return true }, deleteKey: { writes += 1; return true })
                let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings))
                let view = tab.makeView()
                tab.refresh()
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let controls = descendants(view)
                let key = try require(controls.first { $0.identifier?.rawValue == "openai.apiKey" } as? NSSecureTextField)
                let language = try require(controls.first { $0.identifier?.rawValue == "openai.languages" } as? NSTextField)
                try expect(key.stringValue.isEmpty && !tab.hasChanges)
                language.stringValue = "zh-cn, en"
                try expect(tab.hasChanges && writes == 0)
                if case .saved = tab.save() {} else { throw TestFailure(file: #filePath, line: #line, message: "Expected local save") }
                try expect(writes == 0)
                let saved = try settings.configuration()
                try expect(saved.languages == ["zh-cn", "en"])
            }
        }
    }
}
