import AppKit
import Foundation
@testable import AtomVoiceCore

enum OpenAIModelUITests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("OpenAI model fetch activates once and preserves edits and an unlisted selection") {
            try await selectionSurvivesFetch()
        }
        await runner.run("OpenAI model fetch discards old-key responses and preserves choices on failure") {
            try await keyChangeDiscardsResponse()
        }
        await runner.run("Discarding an OpenAI connection draft cancels its model fetch and restores refresh") {
            try await discardCancelsModelFetch()
        }
        await runner.run("OpenAI form shares Doubao columns and fits both models in eight languages") {
            try await localizedFormLayout()
        }
        await runner.run("OpenAI separate hints preserve one draft across model changes and reopening without fetching") {
            try await separateHintsPreserveDraft()
        }
        await runner.run("OpenAI hints and connection save and discard never submit the other utility draft") {
            try await hintsAndConnectionCommitIndependently()
        }
    }

    @MainActor
    private static func separateHintsPreserveDraft() async throws {
        var keyWrites = 0
        var modelFetches = 0
        let settings = fixtureSettings { keyWrites += 1 }
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                   allowsExternalActions: false, loadModels: { _ in
            modelFetches += 1
            return [.live, .whisper]
        })
        let connection = tab.makeView(includeContext: false, allowsModelFetch: false)
        tab.refresh()
        let hints = tab.makeHintsView()
        let scene: NSTextView = try control("openai.hints.prompt", in: hints)
        let keywords: NSTextView = try control("openai.hints.keywords", in: hints)
        let model: NSPopUpButton = try control("openai.model", in: connection)
        let refresh: NSButton = try control("openai.models.refresh", in: connection)
        let key: NSSecureTextField = try control("openai.apiKey", in: connection)
        let originalParent = scene.superview
        try expect(!tab.hasChanges && key.stringValue.isEmpty)
        try expect(scene.window == nil && keywords.window == nil)

        // 通过正式 NSTextViewDelegate 接线修改草稿，而不访问真实设置或钥匙串。
        scene.string = "offline scene"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: scene))
        keywords.string = "AtomVoice\nOpenAI"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: keywords))
        try expect(tab.hasChanges)
        let beforeSave = try settings.configuration()
        try expect(beforeSave.prompt.isEmpty)

        model.selectItem(withTitle: OpenAIASRModel.whisper.rawValue)
        if let action = model.action { _ = model.sendAction(action, to: model.target) }
        try expect(!tab.supportsContextHints && hints.isHidden)
        try expect(!scene.isEditable && !keywords.isEditable)
        try expect(scene.string == "offline scene" && keywords.string == "AtomVoice\nOpenAI")

        // 重新取得缓存视图模拟关闭后再打开，不以 refresh 覆盖未保存内容。
        try expect(tab.makeView(includeContext: false, allowsModelFetch: false) === connection)
        try expect(tab.makeHintsView() === hints && scene.superview === originalParent)
        model.selectItem(withTitle: OpenAIASRModel.live.rawValue)
        if let action = model.action { _ = model.sendAction(action, to: model.target) }
        try expect(tab.supportsContextHints && !hints.isHidden)
        try expect(scene.isEditable && keywords.isEditable)
        try expect(scene.string == "offline scene" && keywords.string == "AtomVoice\nOpenAI")

        tab.activateModelList()
        if let action = refresh.action { _ = refresh.sendAction(action, to: refresh.target) }
        await Task.yield()
        try expect(modelFetches == 0 && keyWrites == 0 && !refresh.isEnabled)
        if case .saved = tab.saveHints() {} else {
            throw TestFailure(file: #filePath, line: #line, message: "Expected shared hints draft to save")
        }
        let saved = try settings.configuration()
        try expect(saved.prompt == "offline scene" && saved.keywords == ["AtomVoice", "OpenAI"])
        try expect(!tab.hasChanges && keyWrites == 0 && modelFetches == 0)
    }

    @MainActor
    private static func hintsAndConnectionCommitIndependently() async throws {
        var keyReads = 0
        var keyWrites = 0
        var storedKey = "offline-original-key"
        let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: {
            keyReads += 1
            return .value(storedKey)
        }, writeKey: { value in
            keyWrites += 1
            storedKey = value
            return true
        }, deleteKey: { keyWrites += 1; return true })
        try settings.save(.init(model: .whisper), keyEdit: .unchanged,
                          previousKeyRead: .value(storedKey))
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                   allowsExternalActions: false, loadModels: { _ in [] })
        let connection = tab.makeView(includeContext: false, allowsModelFetch: false)
        tab.refresh()
        let hints = tab.makeHintsView()
        let scene: NSTextView = try control("openai.hints.prompt", in: hints)
        let keywords: NSTextView = try control("openai.hints.keywords", in: hints)
        let key: NSSecureTextField = try control("openai.apiKey", in: connection)
        let model: NSPopUpButton = try control("openai.model", in: connection)
        let readsAfterOpening = keyReads

        model.selectItem(withTitle: OpenAIASRModel.live.rawValue)
        if let action = model.action { _ = model.sendAction(action, to: model.target) }
        key.stringValue = "offline-pending-key"
        tab.apiKeyDidChange()
        scene.string = "saved hints only"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: scene))
        keywords.string = "AtomVoice"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: keywords))
        try expect(tab.hasConnectionChanges && tab.hasHintChanges)
        if case .saved = tab.saveHints() {} else {
            throw TestFailure(file: #filePath, line: #line, message: "Expected hints-only commit")
        }
        let afterHints = try settings.configuration()
        try expect(afterHints.resolvedModel == .whisper && afterHints.prompt == "saved hints only")
        try expect(afterHints.keywords == ["AtomVoice"])
        try expect(keyWrites == 0 && keyReads == readsAfterOpening && storedKey == "offline-original-key")
        try expect(key.stringValue == "offline-pending-key" && model.titleOfSelectedItem == OpenAIASRModel.live.rawValue)
        try expect(tab.hasConnectionChanges && !tab.hasHintChanges)

        scene.string = "discard this hint"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: scene))
        keywords.string = "discard-keyword"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: keywords))
        tab.discardHints()
        try expect(scene.string == "saved hints only" && keywords.string == "AtomVoice")
        try expect(key.stringValue == "offline-pending-key" && model.titleOfSelectedItem == OpenAIASRModel.live.rawValue)
        try expect(keyReads == readsAfterOpening && keyWrites == 0 && tab.hasConnectionChanges)

        scene.string = "keep this pending hint"
        tab.textDidChange(Notification(name: NSText.didChangeNotification, object: scene))
        if case .saved = tab.save() {} else {
            throw TestFailure(file: #filePath, line: #line, message: "Expected connection-only commit")
        }
        let afterConnection = try settings.configuration()
        try expect(afterConnection.resolvedModel == .live && afterConnection.prompt == "saved hints only")
        try expect(keyWrites == 1 && storedKey == "offline-pending-key")
        try expect(scene.string == "keep this pending hint" && !tab.hasConnectionChanges && tab.hasHintChanges)

        model.selectItem(withTitle: OpenAIASRModel.whisper.rawValue)
        if let action = model.action { _ = model.sendAction(action, to: model.target) }
        tab.discardConnectionChanges()
        try expect(model.titleOfSelectedItem == OpenAIASRModel.live.rawValue)
        try expect(scene.string == "keep this pending hint" && !tab.hasConnectionChanges && tab.hasHintChanges)
    }

    @MainActor
    private static func localizedFormLayout() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"] {
            let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let strings = try require(NSDictionary(contentsOf: url) as? [String: String])
            for width in [CGFloat(552), CGFloat(592)] {
                let settings = fixtureSettings {}
                let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                           localize: { strings[$0] ?? $0 }, loadModels: { _ in [] })
                let page = try require(tab.makeView() as? NSScrollView)
                let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 470))
                page.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(page)
                NSLayoutConstraint.activate([
                    page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    page.topAnchor.constraint(equalTo: host.topAnchor),
                    page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                ])
                tab.refresh()
                let model: NSPopUpButton = try control("openai.model", in: page)
                for option in OpenAIASRModel.allCases {
                    model.selectItem(withTitle: option.rawValue)
                    if let action = model.action { _ = model.sendAction(action, to: model.target) }
                    host.layoutSubtreeIfNeeded()
                    let document = try require(page.documentView)
                    document.layoutSubtreeIfNeeded()
                    let ids = ["openai.apiKey", "openai.model", "openai.delay", "openai.languages"]
                    let frames = try ids.map { id -> CGRect in
                        let field: NSView = try control(id, in: page)
                        return try require(field.superview).convert(field.alignmentRect(forFrame: field.frame), to: document)
                    }
                    for frame in frames {
                        try expect(approximatelyEqual(frame.minX, 144, tolerance: 1), "\(language): form control column shifted: \(frame)")
                        try expect(frame.width > 80 && frame.maxX <= width - 15, "\(language): form control clipped: \(frame)")
                    }
                    try expect(frames[0].maxY < frames[1].minY && frames[1].maxY < frames[2].minY && frames[2].maxY < frames[3].minY)
                    let captions = ["openai.keyStatus", "openai.models.status", "openai.hints"]
                    for id in captions {
                        let label: NSTextField = try control(id, in: page)
                        let frame = try require(label.superview).convert(label.alignmentRect(forFrame: label.frame), to: document)
                        let required = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height ?? 0
                        try expect(approximatelyEqual(frame.minX, 144, tolerance: 1))
                        try expect(required <= frame.height + 1 && frame.maxY <= document.bounds.height + 1, "\(language): caption clipped: \(id) \(frame), requires \(required)")
                    }
                    let prompt: NSTextView = try control("openai.prompt", in: page)
                    let keywords: NSTextView = try control("openai.keywords", in: page)
                    let promptBox = try require(prompt.enclosingScrollView)
                    let keywordsBox = try require(keywords.enclosingScrollView)
                    try expect(approximatelyEqual(promptBox.frame.height, 60) && approximatelyEqual(keywordsBox.frame.height, 60))
                    try expect(prompt.isEditable == option.supportsContext && keywords.isEditable == option.supportsContext)
                }
            }
        }
    }

    @MainActor
    private static func selectionSurvivesFetch() async throws {
        let gate = ModelLoadGate()
        var writes = 0
        let settings = fixtureSettings { writes += 1 }
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                   loadModels: { try await gate.load($0) })
        let view = tab.makeView()
        tab.refresh()
        let model: NSPopUpButton = try control("openai.model", in: view)
        let language: NSTextField = try control("openai.languages", in: view)
        let prompt: NSTextView = try control("openai.prompt", in: view)
        let refresh: NSButton = try control("openai.models.refresh", in: view)
        try expect(gate.keys.isEmpty && !tab.hasChanges)
        language.stringValue = "zh-cn"
        prompt.string = "offline context"
        tab.activateModelList()
        tab.activateModelList()
        try await waitUntil { gate.keys.count == 1 }
        try expect(gate.keys == ["offline-fixture-key"])
        model.selectItem(withTitle: OpenAIASRModel.whisper.rawValue)
        if let action = model.action { _ = model.sendAction(action, to: model.target) }
        gate.complete(.success([.live]))
        try await waitUntil { refresh.isEnabled }
        try expect(model.titleOfSelectedItem == OpenAIASRModel.whisper.rawValue)
        try expect(prompt.string == "offline context" && !prompt.isEditable)
        try expect(tab.hasChanges && writes == 0)
        if case .saved = tab.save() {} else {
            throw TestFailure(file: #filePath, line: #line, message: "Expected local model save")
        }
        let saved = try settings.configuration()
        try expect(saved.resolvedModel == .whisper && saved.languages == ["zh"])
        try expect(saved.prompt == "offline context" && saved.delay == nil && writes == 0)
        try expect(!tab.hasChanges)
    }

    @MainActor
    private static func keyChangeDiscardsResponse() async throws {
        let gate = ModelLoadGate()
        var writes = 0
        let settings = fixtureSettings { writes += 1 }
        try settings.save(.init(model: .whisper), keyEdit: .unchanged, previousKeyRead: .value("offline-fixture-key"))
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                   loadModels: { try await gate.load($0) })
        let view = tab.makeView()
        tab.refresh()
        let model: NSPopUpButton = try control("openai.model", in: view)
        let key: NSSecureTextField = try control("openai.apiKey", in: view)
        let status: NSTextField = try control("openai.models.status", in: view)
        let refresh: NSButton = try control("openai.models.refresh", in: view)
        tab.activateModelList()
        try await waitUntil { gate.keys.count == 1 }
        key.stringValue = "replacement-offline-key"
        tab.apiKeyDidChange()
        gate.complete(.success([.live]))
        try await waitUntil { gate.finishedCount == 1 }
        try expect(status.stringValue == loc("openai.models.keyChanged"))
        try expect(model.titleOfSelectedItem == OpenAIASRModel.whisper.rawValue && writes == 0)
        refresh.performClick(nil)
        try await waitUntil { gate.keys.count == 2 }
        try expect(gate.keys.last == "replacement-offline-key")
        gate.complete(.failure(CloudASRFailure(kind: .transport, message: loc("openai.error.transport"))))
        try await waitUntil { refresh.isEnabled }
        try expect(model.titleOfSelectedItem == OpenAIASRModel.whisper.rawValue)
        try expect(key.stringValue == "replacement-offline-key" && tab.hasChanges && writes == 0)
        tab.cancelModelListFetch()
    }

    @MainActor
    private static func discardCancelsModelFetch() async throws {
        let gate = ModelLoadGate()
        var writes = 0
        let settings = fixtureSettings { writes += 1 }
        let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: .init(settings: settings),
                                   loadModels: { try await gate.load($0) })
        let view = tab.makeView(includeContext: false)
        tab.refresh()
        let key: NSSecureTextField = try control("openai.apiKey", in: view)
        let refresh: NSButton = try control("openai.models.refresh", in: view)
        let status: NSTextField = try control("openai.models.status", in: view)
        key.stringValue = "discarded-offline-key"
        tab.apiKeyDidChange()
        refresh.performClick(nil)
        try await waitUntil { gate.keys.count == 1 }
        try expect(!refresh.isEnabled)
        tab.discardConnectionChanges()
        try expect(refresh.isEnabled && key.stringValue.isEmpty && !tab.hasConnectionChanges)
        gate.complete(.success([.whisper]))
        try await waitUntil { gate.finishedCount == 1 }
        try expect(refresh.isEnabled && status.stringValue == loc("openai.models.initial"))
        refresh.performClick(nil)
        try await waitUntil { gate.keys.count == 2 }
        try expect(gate.keys.last == "offline-fixture-key")
        gate.complete(.success([.live]))
        try await waitUntil { refresh.isEnabled }
        try expect(writes == 0 && !tab.hasConnectionChanges)
    }

    private static func fixtureSettings(onWrite: @escaping () -> Void) -> OpenAIASRSettings {
        OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: { .value("offline-fixture-key") },
                          writeKey: { _ in onWrite(); return true }, deleteKey: { onWrite(); return true })
    }

    @MainActor
    private static func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return try require(descendants(view).first { $0.identifier?.rawValue == identifier } as? T)
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TestFailure(file: #filePath, line: #line, message: "Timed out waiting for model UI")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
private final class ModelLoadGate {
    var keys: [String] = []
    var finishedCount = 0
    private var continuation: CheckedContinuation<[OpenAIASRModel], Error>?

    func load(_ key: String) async throws -> [OpenAIASRModel] {
        keys.append(key)
        defer { finishedCount += 1 }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(_ result: Result<[OpenAIASRModel], Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
