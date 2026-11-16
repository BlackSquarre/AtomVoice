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

    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

}
