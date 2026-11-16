import AppKit
import Foundation
@testable import AtomVoiceCore

/// 仅用内存 store、纯尺寸计算及未挂窗的视图；不打开 App 或系统能力。
enum PreferencesLayoutTests {
    private static let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"]

    static func run(_ runner: inout TestRunner) async {
        await runner.run("Appearance preference defaults and invalid stored values follow the system") {
            let backend = InMemorySettingsBackend()
            let settings = InterfaceSettings(backend: backend)
            try expect(settings.appearanceMode == .system)
            backend.set("unsupported", forKey: AppSettings.Keys.appearanceMode)
            try expect(settings.appearanceMode == .system)
            try expect(backend.string(forKey: AppSettings.Keys.appearanceMode) == "unsupported")
            backend.set("minimal", forKey: AppSettings.Keys.animationStyle)
            settings.appearanceMode = .dark
            try expect(backend.string(forKey: AppSettings.Keys.appearanceMode) == "dark")
            try expect(settings.animationStyle == "minimal")
        }

        await runner.run("Settings uses the requested compact width while keeping screen-relative geometry") {
            try expect(approximatelyEqual(UnifiedSettingsWindowController.preferredContentWidth, 470))
            let next = PreferencesWindowGeometry.targetFrame(
                currentFrame: NSRect(x: 200, y: 150, width: 760, height: 600),
                visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                contentSize: NSSize(width: UnifiedSettingsWindowController.preferredContentWidth, height: 460),
                frameInsets: NSSize(width: 0, height: 80)
            )
            try expect(approximatelyEqual(next.width, 470))
            try expect(approximatelyEqual(next.maxY, 750))
            try expect(approximatelyEqual(next.midX, 580))
        }

        await runner.run("Preferences resize keeps its top edge and horizontal center") {
            let current = NSRect(x: 300, y: 350, width: 600, height: 450)
            let next = PreferencesWindowGeometry.targetFrame(
                currentFrame: current,
                visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                contentSize: NSSize(width: 760, height: 240),
                frameInsets: NSSize(width: 0, height: 80)
            )
            try expect(approximatelyEqual(next.maxY, current.maxY))
            try expect(approximatelyEqual(next.midX, current.midX))
            try expect(approximatelyEqual(next.width, 760))
            try expect(approximatelyEqual(next.height, 320))
        }

        await runner.run("Preferences resize clamps to a secondary screen with negative coordinates") {
            let visible = NSRect(x: -1280, y: 120, width: 1280, height: 800)
            let next = PreferencesWindowGeometry.targetFrame(
                currentFrame: NSRect(x: -120, y: 100, width: 600, height: 450),
                visibleFrame: visible,
                contentSize: NSSize(width: 760, height: 480),
                frameInsets: NSSize(width: 0, height: 80)
            )
            try expect(visible.contains(next))
            try expect(approximatelyEqual(next.maxX, visible.maxX))
            try expect(approximatelyEqual(next.maxY, visible.minY + next.height))
        }

        await runner.run("Preferences long content stays inside even a very small visible frame") {
            let visible = NSRect(x: 50, y: 70, width: 430, height: 210)
            let next = PreferencesWindowGeometry.targetFrame(
                currentFrame: NSRect(x: -100, y: -100, width: 760, height: 650),
                visibleFrame: visible,
                contentSize: NSSize(width: 760, height: 1600),
                frameInsets: NSSize(width: 0, height: 80)
            )
            try expect(next == visible)
        }

        await runner.run("Preferences geometry preserves its frame when no usable screen is supplied") {
            let current = NSRect(x: 20, y: 30, width: 760, height: 400)
            let next = PreferencesWindowGeometry.targetFrame(
                currentFrame: current,
                visibleFrame: .zero,
                contentSize: NSSize(width: 760, height: 200),
                frameInsets: .zero
            )
            try expect(next == current)
        }

        await runner.run("Appearance pane uses only its injected store in fixture mode") {
            try await MainActor.run {
                let backend = InMemorySettingsBackend()
                let settings = InterfaceSettings(backend: backend)
                settings.animationStyle = "dynamicIsland"
                settings.animationSpeed = "fast"
                let globalAppearance = NSApp?.appearance
                let windowCount = NSApp?.windows.count
                let defaults = UserDefaults.standard
                let keys = [AppSettings.Keys.appearanceMode, AppSettings.Keys.animationStyle, AppSettings.Keys.animationSpeed]
                let original = keys.map { defaults.object(forKey: $0) as? String }
                var changed = 0
                let pane = PreferencesAppearancePane(interfaceSettings: settings, appliesApplicationAppearance: false)
                let view = pane.makeView(onSizeChanged: {}, onChanged: { changed += 1 })
                let radios = descendants(view).compactMap { $0 as? NSButton }.filter {
                    $0.identifier?.rawValue.hasPrefix("appearance-") == true
                }
                try expect(radios.count == 3)
                let dark = try require(radios.first { $0.identifier?.rawValue == "appearance-dark" })
                try invokeAction(dark)
                try expect(dark.state == .on && radios.filter { $0.state == .on }.count == 1,
                           "Native appearance radio buttons must be mutually exclusive")
                let popups = descendants(view).compactMap { $0 as? NSPopUpButton }
                let style = try require(popups.first { $0.itemArray.contains { ($0.representedObject as? String) == "minimal" } })
                style.selectItem(at: 1)
                try invokeAction(style)
                try expect(settings.appearanceMode == .dark)
                try expect(settings.animationStyle == "minimal")
                try expect(changed == 2)
                let waveform = try require(descendants(view).compactMap { $0 as? WaveformView }.first)
                let capsule = try require(waveform.superview)
                try expect(descendants(capsule).compactMap { $0 as? NSTextField }.isEmpty,
                           "The capsule preview must not invent recognition text")
                if #available(macOS 26.0, *) {
                    let glass = try require(descendants(view).compactMap { $0 as? NSGlassEffectView }.first)
                    try expect(approximatelyEqual(glass.cornerRadius, 21), "The preview must use the production glass capsule radius")
                }
                style.selectItem(at: 2)
                try invokeAction(style)
                try expect(settings.animationStyle == "none")
                try expect(waveform.isHiddenOrHasHiddenAncestor, "No capsule must also hide its waveform preview")
                try expect(NSApp?.appearance === globalAppearance)
                try expect(NSApp?.windows.count == windowCount)
                try expect(keys.map { defaults.object(forKey: $0) as? String } == original)
                withExtendedLifetime(pane) {}
            }
        }

        await runner.run("Unified preferences controls browse engines before activation and preserve memory-only switches") {
            try await MainActor.run {
                let preferences = UnifiedSettingsWindowController(llmRefiner: LLMRefiner(), sherpaDownloadReporter: nil, allowsSideEffects: false)
                let first = preferences.makePreviewContent(page: .mode)
                let picker = try require(descendants(first).compactMap { $0 as? NSPopUpButton }.first)
                let index = try require(picker.itemArray.firstIndex { ($0.representedObject as? String) == "openai" })
                picker.selectItem(at: index)
                try invokeAction(picker)
                let browsed = preferences.makePreviewContent(page: .mode)
                let activate = try require(descendants(browsed).compactMap { $0 as? NSButton }.first { $0.title == loc("preferences.useEngine") })
                try invokeAction(activate)
                let active = preferences.makePreviewContent(page: .mode)
                try expect(!descendants(active).compactMap { $0 as? NSButton }.contains { $0.title == loc("preferences.useEngine") })
                let refinement = try require(descendants(active).compactMap { $0 as? NSSwitch }.first {
                    $0.accessibilityLabel() == loc("preferences.refinement")
                })
                refinement.state = .on
                try invokeAction(refinement)
                let enabled = preferences.makePreviewContent(page: .mode)
                try expect(descendants(enabled).compactMap { $0 as? NSPopUpButton }.count == 1,
                           "OpenAI refinement has one fixed provider, without a second provider picker")
                try expect(descendants(enabled).compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue == AppSettings.defaultLLMModel
                })

                for engine in ["apple", "sherpaOnnx", "doubao"] {
                    let page = preferences.makePreviewContent(page: .mode)
                    let enginePicker = try require(descendants(page).compactMap { $0 as? NSPopUpButton }.first)
                    let engineIndex = try require(enginePicker.itemArray.firstIndex { ($0.representedObject as? String) == engine })
                    enginePicker.selectItem(at: engineIndex)
                    try invokeAction(enginePicker)
                    let unsupported = preferences.makePreviewContent(page: .mode)
                    try expect(!descendants(unsupported).compactMap { $0 as? NSSwitch }.contains {
                        $0.accessibilityLabel() == loc("preferences.refinement")
                    }, "\(engine): merely browsing an unsupported engine must hide its refinement switch")
                    let labels = descendants(unsupported).compactMap { $0 as? NSTextField }.map(\.stringValue)
                    try expect(!labels.contains(loc("preferences.refinement")) && !labels.contains(loc("preferences.refinementRules")),
                               "\(engine): the entire independent refinement section must be absent")
                }

                let lastPage = preferences.makePreviewContent(page: .mode)
                let lastPicker = try require(descendants(lastPage).compactMap { $0 as? NSPopUpButton }.first)
                let openAIIndex = try require(lastPicker.itemArray.firstIndex { ($0.representedObject as? String) == "openai" })
                lastPicker.selectItem(at: openAIIndex)
                try invokeAction(lastPicker)
                let restored = preferences.makePreviewContent(page: .mode)
                let restoredSwitch = try require(descendants(restored).compactMap { $0 as? NSSwitch }.first {
                    $0.accessibilityLabel() == loc("preferences.refinement")
                })
                try expect(restoredSwitch.state == .on, "Browsing other engines must not clear the saved refinement switch")
                try expect(descendants(restored).compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue == AppSettings.defaultLLMModel
                }, "Returning to OpenAI must retain its refinement model")
                try expect(descendants(restored).compactMap { $0 as? NSPopUpButton }.count == 1)
            }
        }

        await runner.run("Fixed OpenAI refinement form hides provider choice and preserves its unsaved draft when refreshed") {
            try await MainActor.run {
                let controller = SettingsWindowController(llmRefiner: LLMRefiner(), allowsSideEffects: false)
                var saves = 0
                let view = controller.makeEmbeddedView(provider: .openAI, parentWindow: { nil },
                                                       onSizeChanged: {}, onSaved: { saves += 1 })
                if let providerRow = descendants(view).first(where: { $0.identifier?.rawValue == "llm.provider" }) {
                    try expect(providerRow.isHiddenOrHasHiddenAncestor)
                }
                try expect(!descendants(view).compactMap { $0 as? NSPopUpButton }.contains { !$0.isHiddenOrHasHiddenAncestor },
                           "The fixed provider must not offer a visible provider popup")
                let url = try require(descendants(view).compactMap { $0 as? NSTextField }.first {
                    $0.identifier?.rawValue == "llm.apiBaseURL"
                })
                let key = try require(descendants(view).compactMap { $0 as? NSSecureTextField }.first {
                    $0.identifier?.rawValue == "llm.apiKey"
                })
                let model = try require(descendants(view).compactMap { $0 as? NSTextField }.first {
                    $0.identifier?.rawValue == "llm.model"
                })
                try expect(url.stringValue == RefinementProvider.openAI.baseURL && !url.isEditable && url.isSelectable)
                try expect(!controller.hasEmbeddedChanges)
                model.stringValue = "offline-unsaved-model"
                controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: model))
                key.stringValue = "offline-unsaved-key"
                controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: key))
                try expect(controller.hasEmbeddedChanges)

                controller.refreshEmbeddedStatus()
                let reopened = controller.makeEmbeddedView(provider: .openAI, parentWindow: { nil },
                                                           onSizeChanged: {}, onSaved: { saves += 1 })
                try expect(reopened === view && model.stringValue == "offline-unsaved-model")
                try expect(key.stringValue == "offline-unsaved-key" && controller.hasEmbeddedChanges)
                try expect(url.stringValue == RefinementProvider.openAI.baseURL && !url.isEditable)
                try expect(saves == 0 && view.window == nil, "Refreshing a draft must not submit it or open a window")
                controller.discardEmbeddedChanges()
                try expect(model.stringValue == RefinementProvider.openAI.model && key.stringValue.isEmpty)
                try expect(!controller.hasEmbeddedChanges && saves == 0)
                withExtendedLifetime(controller) {}
            }
        }

        await runner.run("Native settings footer keeps its primary action at the trailing edge") {
            try await MainActor.run {
                let save = NSButton(title: "Save", target: nil, action: nil)
                let footer = SettingsUI.makeBottomRow(statusLabel: NSTextField(labelWithString: ""), buttons: [NSButton(title: "Cancel", target: nil, action: nil), save])
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
                host.addSubview(footer)
                NSLayoutConstraint.activate([
                    footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    footer.topAnchor.constraint(equalTo: host.topAnchor),
                ])
                host.layoutSubtreeIfNeeded()
                let actionRect = save.alignmentRect(forFrame: save.frame)
                try expect(abs(actionRect.maxX - footer.bounds.maxX) < 1)
            }
        }

        await runner.run("Reused trigger keyboard exposes six accessible keys and keeps selection in sync") {
            try await MainActor.run {
                let keyboard = KeyboardDiagramView(frame: .zero)
                let keys = try require(keyboard.accessibilityChildren() as? [KeyCap])
                try expect(keys.count == 6)
                try expect(keys.map { $0.keyCode } == [63, 59, 58, 54, 61, 62])
                var selected: UInt16?
                keyboard.onSelect = { selected = $0 }
                for key in keys {
                    try expect(key.accessibilityRole() == .button)
                    try expect(!(key.accessibilityLabel() ?? "").isEmpty)
                    try expect(key.accessibilityPerformPress())
                    try expect(selected == key.keyCode)
                    try expect(keys.filter { $0.isAccessibilitySelected() }.count == 1)
                    try expect(key.isAccessibilitySelected())
                }
            }
        }

        await runner.run("Composite permission actions align their actual buttons across different copy lengths") {
            let root = try repositoryRoot()
            for locale in locales {
                let strings = try localizedStrings(locale: locale, root: root)
                try await MainActor.run {
                    var buttons: [NSButton] = []
                    var states: [NSTextField] = []
                    let rows = try ["accessibility", "microphone", "speech"].map { kind -> NSView in
                        let state = NSTextField(labelWithString: try localized("permission.status.granted", strings: strings, locale: locale))
                        let button = NSButton(title: try localized("preferences.systemSettings", strings: strings, locale: locale), target: nil, action: nil)
                        button.bezelStyle = .rounded
                        buttons.append(button); states.append(state)
                        let actions = NSStackView(views: [state, button]); actions.spacing = 10
                        return PreferencesLayout.row(
                            title: try localized("permission.\(kind).title", strings: strings, locale: locale),
                            detail: try localized("preferences.\(kind).detail", strings: strings, locale: locale), control: actions)
                    }
                    let page = PreferencesLayout.group(rows: rows)
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 414, height: 1000))
                    host.addSubview(page)
                    NSLayoutConstraint.activate([
                        page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        page.topAnchor.constraint(equalTo: host.topAnchor),
                        page.widthAnchor.constraint(equalToConstant: 414),
                    ])
                    host.layoutSubtreeIfNeeded()
                    for (index, button) in buttons.enumerated() {
                        try expect(abs(button.frame.width - button.intrinsicContentSize.width) < 1,
                                   "\(locale): native action must not stretch to fill leftover width")
                        let rect = try require(button.superview).convert(button.alignmentRect(forFrame: button.frame), to: rows[index])
                        try expect(abs(rect.maxX - (rows[index].bounds.width - 14)) < 1,
                                   "\(locale): the button itself, not just its container, must reach the right inset")
                        let status = states[index]
                        let statusRect = try require(status.superview).convert(status.alignmentRect(forFrame: status.frame), to: rows[index])
                        try expect(abs(rect.minX - statusRect.maxX - 10) < 1,
                                   "\(locale): permission status and button must remain adjacent")
                    }
                }
            }
        }

        await runner.run("Preferences cards wrap actual copy in all eight locales without fixed label widths") {
            let root = try repositoryRoot()
            for locale in locales {
                let strings = try localizedStrings(locale: locale, root: root)
                _ = try localized("preferences.hints.scene", strings: strings, locale: locale)
                let title = try localized("preferences.appearance.mode", strings: strings, locale: locale)
                let detail = try localized("preferences.appleLive.detail", strings: strings, locale: locale)
                let groupTitle = try localized("preferences.appearance.capsule", strings: strings, locale: locale)
                try await MainActor.run {
                    for width in [CGFloat(414), CGFloat(400)] {
                        let control = NSSwitch()
                        let row = PreferencesLayout.row(title: title, detail: detail, control: control)
                        let page = PreferencesLayout.column([PreferencesLayout.group(title: groupTitle, rows: [row])])
                        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
                        host.addSubview(page)
                        NSLayoutConstraint.activate([
                            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                            page.topAnchor.constraint(equalTo: host.topAnchor),
                            page.widthAnchor.constraint(equalToConstant: width),
                        ])
                        host.layoutSubtreeIfNeeded()
                        try expect(abs(row.bounds.width - (width - 2)) < 1, "\(locale): card row must fill the box inside its one-point border")
                        let controlFrame = try require(control.superview).convert(control.alignmentRect(forFrame: control.frame), to: row)
                        try expect(abs(controlFrame.maxX - (row.bounds.width - 14)) < 1,
                                   "\(locale): control must align to the trailing card inset")
                        try expect(abs(page.arrangedSubviews[0].frame.minX) < 1, "\(locale): card must align to its column")
                        try expect(page.fittingSize.height > 24, "\(locale): group must retain its natural content height")
                        for label in descendants(page).compactMap({ $0 as? NSTextField }) {
                            let required = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height ?? 0
                            try expect(label.bounds.width > 0 && required <= label.bounds.height + 1,
                                       "\(locale), width \(width): clipped label \(label.stringValue)")
                            try expect(label.maximumNumberOfLines == 0 && label.lineBreakMode == .byWordWrapping)
                        }
                    }
                }
            }
        }
    }

    private static func invokeAction(_ control: NSControl) throws {
        let target = try require(control.target as? NSObject)
        let action = try require(control.action)
        _ = target.perform(action, with: control)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while root.path != "/" {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { return root }
            root.deleteLastPathComponent()
        }
        throw TestFailure(file: #filePath, line: #line, message: "could not locate repository root")
    }

    private static func localizedStrings(locale: String, root: URL) throws -> [String: String] {
        let file = root.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        return try require(NSDictionary(contentsOf: file) as? [String: String])
    }

    private static func localized(_ key: String, strings: [String: String], locale: String) throws -> String {
        guard let value = strings[key], !value.isEmpty else {
            throw TestFailure(file: #filePath, line: #line, message: "\(locale) missing \(key)")
        }
        return value
    }
}
