import Foundation
@testable import AtomVoiceCore

enum AppSettingsBackendTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("In-memory settings backend stores defaults and notifies observers") {
            let backend = InMemorySettingsBackend()
            backend.register(defaults: [
                "string": "default",
                "bool": true,
                "double": 1.5,
                "int": 2,
            ])

            try expect(backend.string(forKey: "string") == "default")
            try expect(backend.bool(forKey: "bool", default: false))
            try expect(approximatelyEqual(backend.double(forKey: "double", default: 0), 1.5))
            try expect(backend.integer(forKey: "int", default: 0) == 2)

            var observed = 0
            let observation = backend.observe(key: "string") { observed += 1 }
            backend.set("updated", forKey: "string")
            try expect(backend.string(forKey: "string") == "updated")
            try expect(observed == 1)

            observation.cancel()
            backend.set("ignored", forKey: "string")
            try expect(observed == 1)
        }

        await runner.run("Recognition settings preserve engine notification contract") {
            let backend = InMemorySettingsBackend()
            backend.register(defaults: [
                AppSettings.Keys.recognitionEngine: ASREngineRegistry.appleCode,
                AppSettings.Keys.sherpaProvider: AppSettings.defaultSherpaProvider,
            ])
            let settings = RecognitionSettings(backend: backend)

            var changedKeys: [String] = []
            var notificationObjects: [AnyObject] = []
            let token = NotificationCenter.default.addObserver(
                forName: AppSettings.recognitionEngineSettingsDidChangeNotification,
                object: backend,
                queue: nil
            ) { notification in
                if let key = notification.userInfo?[AppSettings.recognitionEngineSettingsChangedKey] as? String {
                    changedKeys.append(key)
                }
                if let object = notification.object as AnyObject? {
                    notificationObjects.append(object)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            settings.engine = ASREngineRegistry.sherpaCode
            settings.engine = ASREngineRegistry.sherpaCode
            settings.sherpaProvider = "cpu"

            try expect(changedKeys == [AppSettings.Keys.recognitionEngine, AppSettings.Keys.sherpaProvider])
            try expect(notificationObjects.count == 2)
            try expect(notificationObjects.allSatisfy { $0 === backend })
        }

        await runner.run("LLM settings enabled posts typed notification") {
            let backend = InMemorySettingsBackend()
            backend.register(defaults: [AppSettings.Keys.llmEnabled: false])
            let settings = LLMSettings(backend: backend)

            var notifications = 0
            let token = NotificationCenter.default.addObserver(
                forName: LLMSettings.enabledDidChangeNotification,
                object: backend,
                queue: nil
            ) { _ in
                notifications += 1
            }
            defer { NotificationCenter.default.removeObserver(token) }

            settings.enabled = true
            settings.enabled = true

            try expect(settings.enabled)
            try expect(notifications == 1)
        }

        await runner.run("Audio settings keep lower volume default true") {
            let backend = InMemorySettingsBackend()
            backend.register(defaults: [AppSettings.Keys.lowerVolumeOnRecording: true])
            let settings = AudioSettings(backend: backend)

            try expect(settings.lowerVolumeOnRecording)

            settings.lowerVolumeOnRecording = false
            try expect(!settings.lowerVolumeOnRecording)
        }

        await runner.run("AppSettings facade writes existing UserDefaults keys") {
            let defaults = UserDefaults.standard
            let oldEngine = defaults.object(forKey: AppSettings.Keys.recognitionEngine)
            let oldLLMEnabled = defaults.object(forKey: AppSettings.Keys.llmEnabled)
            let oldLowerVolume = defaults.object(forKey: AppSettings.Keys.lowerVolumeOnRecording)
            defer {
                restoreDefaultsObject(oldEngine, forKey: AppSettings.Keys.recognitionEngine)
                restoreDefaultsObject(oldLLMEnabled, forKey: AppSettings.Keys.llmEnabled)
                restoreDefaultsObject(oldLowerVolume, forKey: AppSettings.Keys.lowerVolumeOnRecording)
            }

            AppSettings.recognitionEngine = ASREngineRegistry.appleCode
            AppSettings.llmEnabled = true
            AppSettings.lowerVolumeOnRecording = false

            try expect(defaults.string(forKey: AppSettings.Keys.recognitionEngine) == ASREngineRegistry.appleCode)
            try expect(defaults.bool(forKey: AppSettings.Keys.llmEnabled))
            try expect(!defaults.bool(forKey: AppSettings.Keys.lowerVolumeOnRecording))
        }
    }
}
