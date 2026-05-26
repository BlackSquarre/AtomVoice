import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum AppSettingsNotificationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("App settings posts precise recognition engine notifications") {
            let defaults = UserDefaults.standard
            let oldEngine = defaults.object(forKey: AppSettings.Keys.recognitionEngine)
            let oldProvider = defaults.object(forKey: AppSettings.Keys.sherpaProvider)
            let unrelatedKey = "AtomVoiceArchitectureTests.unrelatedDefaultsKey"
            defer {
                restoreDefaultsObject(oldEngine, forKey: AppSettings.Keys.recognitionEngine)
                restoreDefaultsObject(oldProvider, forKey: AppSettings.Keys.sherpaProvider)
                defaults.removeObject(forKey: unrelatedKey)
            }

            var changedKeys: [String] = []
            let token = NotificationCenter.default.addObserver(
                forName: AppSettingsEventBus.recognitionEngineNotification,
                object: defaults,
                queue: nil
            ) { notification in
                if case .recognitionEngineSettingsChanged(let key) = AppSettingsEventBus.decode(notification) {
                    changedKeys.append(key)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            AppSettings.recognitionEngine = ASREngineRegistry.appleCode
            changedKeys.removeAll()

            defaults.set("unrelated", forKey: unrelatedKey)
            AppSettings.recognitionEngine = ASREngineRegistry.sherpaCode
            AppSettings.recognitionEngine = ASREngineRegistry.sherpaCode
            AppSettings.sherpaProvider = "cpu"

            try expect(changedKeys == [AppSettings.Keys.recognitionEngine, AppSettings.Keys.sherpaProvider])
        }
    }
}
