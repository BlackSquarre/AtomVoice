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
        await runner.run("OpenAI form shares Doubao columns and fits both models in eight languages") {
            try await localizedFormLayout()
        }
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
