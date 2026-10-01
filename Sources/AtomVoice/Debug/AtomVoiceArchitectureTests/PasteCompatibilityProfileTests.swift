import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum PasteCompatibilityProfileTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Safari and independently installed PWAs use native paste") {
            for bundleID in ["com.apple.Safari", "com.apple.SafariTechnologyPreview",
                             "com.apple.Safari.WebApp.E59F6913-97EF-4C2F-B670-0530F7C1D80B",
                             "com.apple.Safari.WebApp.another-site"] {
                try expect(BrowserPasteCompatibility.usesNativePaste(bundleID: bundleID))
            }
            for bundleID in [nil, "", "com.apple.SafariOther", "com.apple.TextEdit", "com.google.Chrome"] {
                try expect(!BrowserPasteCompatibility.usesNativePaste(bundleID: bundleID))
            }
        }
        await runner.run("Native paste menu matching excludes modified and missing shortcuts") {
            try expect(BrowserPasteCompatibility.isPasteShortcut(character: "V", modifiers: 0))
            try expect(BrowserPasteCompatibility.isPasteShortcut(character: "v", modifiers: 0))
            for modifiers in [nil, 1, 2, 4, 8, 3] {
                try expect(!BrowserPasteCompatibility.isPasteShortcut(character: "v", modifiers: modifiers))
            }
            try expect(!BrowserPasteCompatibility.isPasteShortcut(character: nil, modifiers: 0))
            try expect(!BrowserPasteCompatibility.isPasteShortcut(character: "c", modifiers: 0))
        }
        await runner.run("Paste compatibility matches remote desktop apps") {
            let profile = try require(PasteCompatibilityRegistry.profile(forBundleID: "com.microsoft.rdc.macos"))

            try expect(profile.displayName == "Microsoft Remote Desktop")
            try expect(profile.category == .remoteDesktop)
            try expect(approximatelyEqual(profile.pasteDelay, 0.40))
        }
        await runner.run("Paste compatibility matches Apple screen sharing") {
            let profile = try require(PasteCompatibilityRegistry.profile(forBundleID: "com.apple.ScreenSharing"))

            try expect(profile.displayName == "Screen Sharing")
            try expect(profile.category == .remoteDesktop)
            try expect(approximatelyEqual(profile.pasteDelay, PasteCompatibilityCategory.remoteDesktop.pasteDelay))
        }
        await runner.run("Paste compatibility matches local virtual machines") {
            let profile = try require(PasteCompatibilityRegistry.profile(forBundleID: "com.parallels.desktop.console"))

            try expect(profile.displayName == "Parallels Desktop")
            try expect(profile.category == .virtualMachine)
            try expect(approximatelyEqual(profile.pasteDelay, 0.35))
        }
        await runner.run("Paste compatibility matches game streaming apps") {
            let profile = try require(PasteCompatibilityRegistry.profile(forBundleID: "com.parsec.www"))

            try expect(profile.displayName == "Parsec")
            try expect(profile.category == .gameStreaming)
            try expect(approximatelyEqual(profile.pasteDelay, 0.50))
        }
        await runner.run("Paste compatibility returns nil for unknown bundle IDs") {
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "com.microsoft.VSCode") == nil)
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "com.todesktop.230313mzl4w4u92") == nil)
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "com.unknown.editor") == nil)
        }
        await runner.run("Paste compatibility returns nil for empty bundle IDs") {
            try expect(PasteCompatibilityRegistry.profile(forBundleID: nil) == nil)
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "") == nil)
        }
        await runner.run("Paste compatibility bundle ID lookup is case sensitive") {
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "COM.MICROSOFT.RDC.MACOS") == nil)
            try expect(PasteCompatibilityRegistry.profile(forBundleID: "com.apple.screensharing") == nil)
        }
        await runner.run("Paste compatibility category delays stay ordered by latency") {
            try expect(PasteCompatibilityCategory.virtualMachine.pasteDelay < PasteCompatibilityCategory.remoteDesktop.pasteDelay)
            try expect(PasteCompatibilityCategory.remoteDesktop.pasteDelay < PasteCompatibilityCategory.gameStreaming.pasteDelay)
        }
    }
}
