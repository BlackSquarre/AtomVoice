import Darwin
import AVFoundation
import Foundation
@testable import AtomVoiceCore

@main
struct ArchitectureTestRunner {
    static func main() async {
        var runner = TestRunner()

        await runner.run("Access kind maps card tags") {
            try expect(PermissionKind(permissionCardTag: 0) == .accessibility)
            try expect(PermissionKind(permissionCardTag: 1) == .microphone)
            try expect(PermissionKind(permissionCardTag: 2) == .speechRecognition)
            try expect(PermissionKind(permissionCardTag: -1) == nil)
            try expect(PermissionKind(permissionCardTag: 3) == nil)
        }

        await runner.run("Access gate ignores optional voice entitlement") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(service.hasRequiredPermissions(speechRequired: false))
        }

        await runner.run("Access gate requires voice entitlement when requested") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(!service.hasRequiredPermissions(speechRequired: true))

            access.statuses[.speechRecognition] = .granted
            try expect(service.hasRequiredPermissions(speechRequired: true))
        }

        await runner.run("Access gate requests undetermined capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("Access gate opens settings for denied capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 0)
            try expect(access.openedSettings == [.microphone])
        }

        await runner.run("Access gate requests undetermined dictation access") {
            let access = FakePermissionAccess(statuses: [.speechRecognition: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .speechRecognition)

            try expect(access.requestedSpeechRecognitionCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("Access gate opens assistive-control settings") {
            let access = FakePermissionAccess(statuses: [.accessibility: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .accessibility)

            try expect(access.openedSettings == [.accessibility])
        }

        await runner.run("ASR provider shares Apple stack instances") {
            let provider = ASREngineProvider()
            let speechRecognizer = provider.speechRecognizer()
            let appleEngine = provider.appleEngine()

            try expect(speechRecognizer === provider.speechRecognizer())
            try expect(appleEngine === provider.appleEngine())
            try expect(appleEngine.recognizer === speechRecognizer)
        }

        await runner.run("ASR provider releases local engine without model load") {
            let provider = ASREngineProvider()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let sherpaEngine = provider.sherpaEngine()
            try expect(provider.hasSherpaEngine)
            try expect(sherpaEngine === provider.sherpaEngine())
            try expect(!provider.isSherpaModelLoaded)

            provider.releaseSherpaEngine()
            try expect(!provider.hasSherpaEngine)
            try expect(!provider.isSherpaModelLoaded)

            let recreatedSherpaEngine = provider.sherpaEngine()
            try expect(recreatedSherpaEngine !== sherpaEngine)
        }

        await runner.run("ASR provider shares cloud engine instance") {
            let provider = ASREngineProvider()
            let engine = provider.volcengineEngine()

            try expect(engine === provider.volcengineEngine())
        }

        await runner.run("ASR registry normalizes unknown engine codes") {
            let registry = ASREngineRegistry(descriptors: [.sherpaOnnx, .apple, .volcengine])

            try expect(registry.normalizedCode(for: nil) == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: "missing") == ASREngineRegistry.appleCode)
            try expect(registry.normalizedCode(for: ASREngineRegistry.sherpaCode) == ASREngineRegistry.sherpaCode)
        }

        await runner.run("ASR registry keeps cloud boundary explicit") {
            let registry = ASREngineRegistry.shared

            try expect(registry.isCloud(VolcengineASRSettings.engineCode))
            try expect(!registry.isCloud(ASREngineRegistry.appleCode))
            try expect(!registry.isCloud(ASREngineRegistry.sherpaCode))
            try expect(registry.descriptor(for: VolcengineASRSettings.engineCode)?.requiresCredential == true)
            try expect(registry.descriptor(for: ASREngineRegistry.sherpaCode)?.isOffline == true)
        }

        await runner.run("Text processor registry stops at first handler") {
            let first = FakeTextProcessor(id: "first", output: nil)
            let second = FakeTextProcessor(id: "second", output: "handled")
            let third = FakeTextProcessor(id: "third", output: "late")
            let registry = TextPostProcessorRegistry(processors: [first, second, third])
            let context = TextProcessingContext(
                engineCode: ASREngineRegistry.appleCode,
                language: "en-US",
                isImmediateFinish: false
            )

            try expect(registry.run("raw", context: context) == "handled")
            try expect(first.callCount == 1)
            try expect(second.callCount == 1)
            try expect(third.callCount == 0)
        }

        await runner.run("Recognition finalizer delivers processed paste text") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])

            harness.finish("hello")

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(processor.lastContext?.isImmediateFinish == false)
        }

        await runner.run("Recognition finalizer replaces streaming text when punctuation changes") {
            let stream = FakeTextStreamSession()
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])

            harness.finish("hello", streamSession: stream)

            try expect(harness.presenter.events == ["update:hello.", "dismiss"])
            try expect(stream.finalizedReplacements == ["hello."])
            try expect(stream.cancelCount == 0)
            try expect(harness.clearedStreamCount == 1)
        }

        await runner.run("Recognition finalizer appends immediate punctuation without LLM") {
            let processor = FakeTextProcessor(id: "punctuation", output: "hello.")
            let harness = RecognitionFinalizerHarness(processors: [processor])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextResult = "HELLO"

            harness.finish("hello", mode: .immediate(appending: "?"))

            try expect(harness.refiner.requests.isEmpty)
            try expect(harness.sink.deliveredTexts == ["hello?"])
            try expect(processor.lastContext?.isImmediateFinish == true)
        }

        await runner.run("Recognition finalizer runs LLM for paste output") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextProgress = "pol"
            harness.refiner.nextResult = "polished."

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "update:pol", "update:polished.", "dismiss"])
            try expect(harness.sink.deliveredTexts == ["polished."])
        }

        await runner.run("Recognition finalizer delivers processed text when LLM fails") {
            let harness = RecognitionFinalizerHarness(processors: [
                FakeTextProcessor(id: "punctuation", output: "hello.")
            ])
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.refiner.nextError = "LLM failed"

            harness.finish("hello")
            try await waitForAsyncCallbacks()

            try expect(harness.sink.deliveredTexts == ["hello."])
            try expect(harness.presenter.events == ["update:hello.", "refining", "error:LLM failed:3.0"])
        }

        await runner.run("Recognition finalizer handles empty text error fallback") {
            let harness = RecognitionFinalizerHarness()
            let stream = FakeTextStreamSession()

            harness.finish("", errorMessage: "No speech", streamSession: stream)

            try expect(stream.cancelCount == 1)
            try expect(harness.clearedStreamCount == 1)
            try expect(harness.presenter.events == ["error:No speech:5.0"])
            try expect(harness.sink.deliveredTexts.isEmpty)
        }

        await runner.run("Recognition finalizer injects live insertion remainder") {
            let harness = RecognitionFinalizerHarness()

            harness.finish(
                "Hello world again",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello world")
            )

            try expect(harness.sink.deliveredTexts == ["again"])
        }

        await runner.run("Recognition finalizer keeps LLM for streaming after live insertion") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.nextResult = "world polished"
            let stream = FakeTextStreamSession()

            harness.finish(
                "Hello world",
                liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: "Hello"),
                streamSession: stream
            )
            try await waitForAsyncCallbacks()

            try expect(harness.refiner.requests == ["world"])
            try expect(stream.finalizedReplacements == ["world polished"])
            try expect(harness.clearedStreamCount == 1)
        }

        await runner.run("Cloud fallback text merge removes overlap") {
            let merged = DoubaoFallbackCoordinator.combinedText(
                prefix: "hello world",
                cachedText: "world from cache",
                liveText: "cache again"
            )

            try expect(merged == "hello world from cache again")
        }

        await runner.run("Apple speech rolling merge inserts Latin spacing") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "this is a test"
            )

            try expect(merged == "hello world this is a test")
        }

        await runner.run("Apple speech rolling merge removes overlap") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "hello world",
                segment: "world again"
            )

            try expect(merged == "hello world again")
        }

        await runner.run("Apple speech rolling merge keeps CJK tight") {
            let merged = SpeechRecognizerController.mergedSegmentText(
                prefix: "你好世界",
                segment: "继续说"
            )

            try expect(merged == "你好世界继续说")
        }

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

        await runner.run("Model manifest discovers nested files offline") {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let exp = root.appendingPathComponent("exp", isDirectory: true)
            let lang = root.appendingPathComponent("data/lang_char", isDirectory: true)
            try FileManager.default.createDirectory(at: exp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: lang, withIntermediateDirectories: true)

            try writeDummyFile(exp.appendingPathComponent("streaming-encoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-encoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder-int8.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-decoder.onnx"))
            try writeDummyFile(exp.appendingPathComponent("streaming-joiner-int8.onnx"))
            try writeDummyFile(lang.appendingPathComponent("tokens.txt"))

            let manifest = try require(ModelManifest.discover(in: root), "manifest should be discovered")

            try expect(manifest.encoder == "exp/streaming-encoder-int8.onnx")
            try expect(manifest.decoder == "exp/streaming-decoder.onnx")
            try expect(manifest.joiner == "exp/streaming-joiner-int8.onnx")
            try expect(manifest.tokens == "data/lang_char/tokens.txt")
            try expect(manifest.isComplete(in: root))
        }

        await runner.run("Audio router unregisters native consumers") {
            let router = AudioRouter()
            let buffer = try require(makePCMBuffer(sampleRate: 16_000, frameLength: 32), "buffer should be created")
            var firstCount = 0
            var secondCount = 0

            let firstID = router.register(format: nil) { received in
                if received === buffer { firstCount += 1 }
            }
            let secondID = router.register(format: nil) { received in
                if received === buffer { secondCount += 1 }
            }

            router.receive(buffer)
            router.unregister(firstID)
            router.receive(buffer)

            try expect(firstCount == 1)
            try expect(secondCount == 2)
            try expect(secondID != firstID)
        }

        await runner.run("Recognition finalizer ignores LLM results from old generation") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            
            harness.refiner.delayCompletion = true
            harness.generation = 10
            
            harness.finish("hello")
            
            // Verify refiner is called and refining state is true
            try expect(harness.refiner.requests == ["hello"])
            try expect(harness.isRefining == true)
            try expect(harness.presenter.events == ["refining"])
            
            // Advance generation to 11 (simulating cancellation/restarting a session)
            harness.generation = 11
            
            // Fire the delayed completion callbacks for generation 10
            harness.refiner.pendingOnProgress?("progress")
            
            // Trigger completion on main queue since completion executes inside DispatchQueue.main.async block
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            // Verify that the old generation's progress/completion results were completely ignored!
            // No new presenter events and no text delivered to sink!
            try expect(harness.presenter.events == ["refining"]) // remains unchanged, no "update:progress" or "update:polished"
            try expect(harness.sink.deliveredTexts.isEmpty)
        }

        await runner.run("Recognition finalizer updates refining state correctly") {
            let harness = RecognitionFinalizerHarness()
            harness.settings.llmEnabled = true
            harness.settings.llmAPIKey = "test-key"
            harness.settings.llmResultDelay = 0
            harness.refiner.delayCompletion = true
            
            harness.generation = 1
            harness.finish("hello")
            
            try expect(harness.isRefining == true)
            
            harness.refiner.pendingCompletion?("polished", nil)
            try await waitForAsyncCallbacks()
            
            try expect(harness.isRefining == false)
            try expect(harness.sink.deliveredTexts == ["polished"])
        }

        runner.finish()
    }
}

private struct TestRunner {
    private var failures: [String] = []
    private var passed = 0

    mutating func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("All architecture tests passed (\(passed) cases)")
            exit(0)
        }

        print("\nArchitecture test failures:")
        failures.forEach { print("- \($0)") }
        exit(1)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    let message: String

    var description: String {
        "\(file):\(line) \(message)"
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(file: file, line: line, message: message)
    }
}

private func require<T>(
    _ value: T?,
    _ message: String = "required value was nil",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(file: file, line: line, message: message)
    }
    return value
}

private func waitForAsyncCallbacks() async throws {
    try await Task.sleep(nanoseconds: 80_000_000)
}

private func makeTemporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AtomVoiceArchitectureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeDummyFile(_ url: URL) throws {
    try Data([0x41]).write(to: url)
}

private func makePCMBuffer(sampleRate: Double, frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
    buffer.frameLength = frameLength
    if let channel = buffer.floatChannelData?[0] {
        for index in 0..<Int(frameLength) {
            channel[index] = Float(index) / 100.0
        }
    }
    return buffer
}

private final class FakePermissionAccess: PermissionAccessing {
    var statuses: [PermissionKind: PermissionStatus]
    var microphoneRequestResult = true
    var speechRecognitionRequestResult = true
    private(set) var requestedMicrophoneCount = 0
    private(set) var requestedSpeechRecognitionCount = 0
    private(set) var openedSettings: [PermissionKind] = []

    init(statuses: [PermissionKind: PermissionStatus]) {
        self.statuses = statuses
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .denied
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        requestedMicrophoneCount += 1
        completion(microphoneRequestResult)
    }

    func requestSpeechRecognition(completion: @escaping (Bool) -> Void) {
        requestedSpeechRecognitionCount += 1
        completion(speechRecognitionRequestResult)
    }

    func openSettings(for kind: PermissionKind) {
        openedSettings.append(kind)
    }
}

private final class FakeTextProcessor: TextPostProcessor {
    let id: String
    private let output: String?
    private(set) var callCount = 0
    private(set) var lastText: String?
    private(set) var lastContext: TextProcessingContext?

    init(id: String, output: String?) {
        self.id = id
        self.output = output
    }

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        callCount += 1
        lastText = text
        lastContext = context
        return output
    }
}

private final class RecognitionFinalizerHarness {
    let presenter = FakeRecognitionPresenter()
    let refiner = FakeRecognitionRefiner()
    let sink = FakeTextOutputSink()
    let settings: RecognitionFinalizerSettingsBox
    private(set) var clearedStreamCount = 0
    var generation = 0
    var isRefining = false
    private let finalizer: RecognitionResultFinalizer

    init(processors: [TextPostProcessor] = []) {
        let settings = RecognitionFinalizerSettingsBox()
        self.settings = settings
        let finalizer = RecognitionResultFinalizer(
            presenter: presenter,
            refiner: refiner,
            textPostProcessorRegistry: TextPostProcessorRegistry(processors: processors),
            outputSinkProvider: { [sink] in sink },
            settingsProvider: { settings.value }
        )
        self.finalizer = finalizer
        
        finalizer.onRefiningStateChanged = { [weak self] refining in
            self?.isRefining = refining
        }
        finalizer.currentGenerationProvider = { [weak self] in
            self?.generation ?? 0
        }
    }

    func finish(
        _ text: String,
        mode: RecognitionFinalizationMode = .normal,
        errorMessage: String? = nil,
        liveInsertion: RecognitionLiveInsertionSnapshot = RecognitionLiveInsertionSnapshot(isActive: false, committedText: ""),
        streamSession: TextStreamSession? = nil
    ) {
        finalizer.finish(
            RecognitionResultFinalizer.Request(
                recognizedText: text,
                errorMessage: errorMessage,
                mode: mode,
                engineCode: ASREngineRegistry.appleCode,
                liveInsertion: liveInsertion,
                streamSession: streamSession,
                clearStreamSession: { [weak self] in self?.clearedStreamCount += 1 },
                generation: generation
            )
        )
    }
}

private final class RecognitionFinalizerSettingsBox {
    var value = RecognitionResultFinalizer.Settings(
        language: "en-US",
        llmEnabled: false,
        llmAPIKey: "",
        llmResultDelay: 0
    )

    var language: String {
        get { value.language }
        set { value.language = newValue }
    }

    var llmEnabled: Bool {
        get { value.llmEnabled }
        set { value.llmEnabled = newValue }
    }

    var llmAPIKey: String {
        get { value.llmAPIKey }
        set { value.llmAPIKey = newValue }
    }

    var llmResultDelay: Double {
        get { value.llmResultDelay }
        set { value.llmResultDelay = newValue }
    }
}

private final class FakeRecognitionPresenter: RecognitionResultPresenting {
    private(set) var events: [String] = []

    func updateRecognitionText(_ text: String) {
        events.append("update:\(text)")
    }

    func showRecognitionRefining() {
        events.append("refining")
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        events.append(String(format: "error:%@:%0.1f", message, dismissAfter))
    }

    func dismissRecognition(completion: (() -> Void)?) {
        events.append("dismiss")
        completion?()
    }
}

private final class FakeRecognitionRefiner: RecognitionTextRefining {
    var nextProgress: String?
    var nextResult: String?
    var nextError: String?
    private(set) var requests: [String] = []
    var delayCompletion = false
    var pendingCompletion: ((String?, String?) -> Void)?
    var pendingOnProgress: ((String) -> Void)?

    func refine(
        text: String,
        onProgress: ((String) -> Void)?,
        completion: @escaping (String?, String?) -> Void
    ) {
        requests.append(text)
        if delayCompletion {
            pendingCompletion = completion
            pendingOnProgress = onProgress
        } else {
            if let nextProgress {
                onProgress?(nextProgress)
            }
            completion(nextResult, nextError)
        }
    }
}

private final class FakeTextOutputSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(
        code: "fake",
        displayNameKey: "fake",
        iconName: "fake",
        supportsStreaming: false
    )
    private(set) var deliveredTexts: [String] = []

    func deliver(text: String, completion: (() -> Void)?) {
        deliveredTexts.append(text)
        completion?()
    }
}

private final class FakeTextStreamSession: TextStreamSession {
    private(set) var updates: [String] = []
    private(set) var finalizedReplacements: [String?] = []
    private(set) var cancelCount = 0

    func update(currentText: String) {
        updates.append(currentText)
    }

    func finalize(replacingWith finalText: String?, completion: (() -> Void)?) {
        finalizedReplacements.append(finalText)
        completion?()
    }

    func cancel() {
        cancelCount += 1
    }
}
