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

        await runner.run("In-memory settings backend returns string fallback when key is missing") {
            let backend = InMemorySettingsBackend()

            try expect(backend.string(forKey: "missing", default: "fallback") == "fallback")
            backend.set("stored", forKey: "missing")
            try expect(backend.string(forKey: "missing", default: "fallback") == "stored")
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
                forName: AppSettingsEventBus.recognitionEngineNotification,
                object: backend,
                queue: nil
            ) { notification in
                if case .recognitionEngineSettingsChanged(let key) = AppSettingsEventBus.decode(notification) {
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
            var decodedEvents: [AppSettingsEvent] = []
            let token = NotificationCenter.default.addObserver(
                forName: AppSettingsEventBus.llmEnabledNotification,
                object: backend,
                queue: nil
            ) { note in
                notifications += 1
                if let event = AppSettingsEventBus.decode(note) {
                    decodedEvents.append(event)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            settings.enabled = true
            settings.enabled = true

            try expect(settings.enabled)
            try expect(notifications == 1)
            try expect(decodedEvents == [.llmEnabledDidChange])
        }

        await runner.run("Audio settings keep lower volume default true") {
            let backend = InMemorySettingsBackend()
            backend.register(defaults: [AppSettings.Keys.lowerVolumeOnRecording: true])
            let settings = AudioSettings(backend: backend)

            try expect(settings.lowerVolumeOnRecording)

            settings.lowerVolumeOnRecording = false
            try expect(!settings.lowerVolumeOnRecording)
        }

        await runner.run("Interface settings persist capsule window placement") {
            let backend = InMemorySettingsBackend()
            let settings = InterfaceSettings(backend: backend)
            let placement = CapsuleWindowPlacement(screenID: 42, centerXRatio: 0.32, bottomOffset: 88)

            settings.capsuleWindowPlacement = placement

            try expect(settings.capsuleWindowPlacement == placement)

            settings.capsuleWindowPlacement = nil
            try expect(settings.capsuleWindowPlacement == nil)
        }

        await runner.run("AppSettings facade writes existing UserDefaults keys") {
            let defaults = UserDefaults.standard
            let oldEngine = defaults.object(forKey: AppSettings.Keys.recognitionEngine)
            let oldLLMEnabled = defaults.object(forKey: AppSettings.Keys.llmEnabled)
            let oldLowerVolume = defaults.object(forKey: AppSettings.Keys.lowerVolumeOnRecording)
            let oldCapsulePlacement = defaults.object(forKey: AppSettings.Keys.capsuleWindowPlacement)
            defer {
                restoreDefaultsObject(oldEngine, forKey: AppSettings.Keys.recognitionEngine)
                restoreDefaultsObject(oldLLMEnabled, forKey: AppSettings.Keys.llmEnabled)
                restoreDefaultsObject(oldLowerVolume, forKey: AppSettings.Keys.lowerVolumeOnRecording)
                restoreDefaultsObject(oldCapsulePlacement, forKey: AppSettings.Keys.capsuleWindowPlacement)
            }

            AppSettings.recognitionEngine = ASREngineRegistry.appleCode
            AppSettings.llmEnabled = true
            AppSettings.lowerVolumeOnRecording = false
            let placement = CapsuleWindowPlacement(screenID: 7, centerXRatio: 0.5, bottomOffset: 54)
            AppSettings.capsuleWindowPlacement = placement

            try expect(defaults.string(forKey: AppSettings.Keys.recognitionEngine) == ASREngineRegistry.appleCode)
            try expect(defaults.bool(forKey: AppSettings.Keys.llmEnabled))
            try expect(!defaults.bool(forKey: AppSettings.Keys.lowerVolumeOnRecording))
            try expect(AppSettings.capsuleWindowPlacement == placement)
        }
    }
}
