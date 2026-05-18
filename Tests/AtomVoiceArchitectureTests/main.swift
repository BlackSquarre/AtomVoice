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

        await runner.run("Cloud fallback text merge removes overlap") {
            let merged = DoubaoFallbackCoordinator.combinedText(
                prefix: "hello world",
                cachedText: "world from cache",
                liveText: "cache again"
            )

            try expect(merged == "hello world from cache again")
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

    init(id: String, output: String?) {
        self.id = id
        self.output = output
    }

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        callCount += 1
        return output
    }
}
