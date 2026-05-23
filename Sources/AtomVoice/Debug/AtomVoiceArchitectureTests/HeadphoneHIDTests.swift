import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum HeadphoneHIDTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Headphone HID trusts non-keyboard USB consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x1234,
                productID: 0x5678,
                locationID: 1,
                manufacturer: "MOONDROP",
                product: "MAY Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(decision.isTrusted)
        }
        await runner.run("Headphone HID rejects keyboard consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Bluetooth",
                vendorID: 0x05AC,
                productID: 0x029C,
                locationID: 1,
                manufacturer: "Apple Inc.",
                product: "Magic Keyboard",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    ),
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.genericDesktopPage,
                        usage: HeadphoneHIDSourceClassifier.keyboardUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-usage")
        }
        await runner.run("Headphone HID rejects unknown source by default") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: nil,
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: nil,
                product: nil,
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "unsupported-transport")
        }
        await runner.run("Headphone HID rejects AirPods names") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Bluetooth",
                vendorID: 0x05AC,
                productID: 0x1234,
                locationID: 1,
                manufacturer: "Apple Inc.",
                product: "Lingru's AirPods Pro",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "airpods-unsupported")
        }
        await runner.run("Headphone HID rejects keyboard property hints") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x1234,
                productID: 0x5678,
                locationID: 1,
                manufacturer: "Generic",
                product: "Consumer Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: true,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-property")
        }
        await runner.run("Headphone HID rejects ambiguous USB receiver names") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "USB",
                vendorID: 0x046D,
                productID: 0xC548,
                locationID: 1,
                manufacturer: "Logitech",
                product: "USB Receiver",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "keyboard-name")
        }
        await runner.run("Headphone HID trusts named audio headset control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Audio",
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: "Apple",
                product: "Headset",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: [
                    HeadphoneHIDUsagePair(
                        usagePage: HeadphoneHIDSourceClassifier.consumerPage,
                        usage: HeadphoneHIDSourceClassifier.consumerControlUsage
                    )
                ]
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(decision.isTrusted)
        }
        await runner.run("Headphone HID rejects generic audio consumer control") {
            let descriptor = HeadphoneHIDDeviceDescriptor(
                transport: "Audio",
                vendorID: nil,
                productID: nil,
                locationID: nil,
                manufacturer: "Generic",
                product: "Consumer Control",
                primaryUsagePage: HeadphoneHIDSourceClassifier.consumerPage,
                primaryUsage: HeadphoneHIDSourceClassifier.consumerControlUsage,
                isBuiltIn: false,
                conformsToKeyboard: false,
                hasKeyboardPropertyHint: false,
                usagePairs: []
            )

            let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)

            try expect(!decision.isTrusted)
            try expect(decision.reason == "unsupported-transport")
        }
    }
}
