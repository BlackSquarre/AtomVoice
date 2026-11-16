import Foundation
@testable import AtomVoiceCore

enum ExternalDestinationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Sound settings tries modern legacy and app destinations in order") {
            var seen: [String] = []
            var failures = 0
            let opener = ExternalDestinationOpener(openURL: { url in
                seen.append(url.absoluteString)
                return url.isFileURL
            }, applicationURL: { _ in URL(fileURLWithPath: "/fixture/System Settings.app") },
               reportFailure: { failures += 1 })
            try expect(opener.openSoundSettings())
            try expect(seen.count == 3 && seen[0].contains("Sound-Settings") && seen[1].contains("preference.sound"))
            try expect(failures == 0)
        }
        await runner.run("Destination failures report once while successful opens stay quiet") {
            var failures = 0
            var calls = 0
            var opener = ExternalDestinationOpener(openURL: { _ in calls += 1; return false },
                                                  applicationURL: { _ in nil }, reportFailure: { failures += 1 })
            try expect(!opener.openSoundSettings() && calls == 2 && failures == 1)
            opener.openURL = { _ in true }
            try expect(opener.open(URL(string: "https://example.invalid")!) && failures == 1)
            opener.openURL = { _ in false }
            try expect(!opener.open(URL(string: "https://example.invalid")!) && failures == 2)
        }
    }
}
