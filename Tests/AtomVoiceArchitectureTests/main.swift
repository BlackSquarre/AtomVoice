import Darwin
import Foundation
@testable import AtomVoiceCore

@main
struct ArchitectureTestRunner {
    static func main() async {
        var runner = TestRunner()

        await runner.run("PermissionKind maps card tags") {
            try expect(PermissionKind(permissionCardTag: 0) == .accessibility)
            try expect(PermissionKind(permissionCardTag: 1) == .microphone)
            try expect(PermissionKind(permissionCardTag: 2) == .speechRecognition)
            try expect(PermissionKind(permissionCardTag: -1) == nil)
            try expect(PermissionKind(permissionCardTag: 3) == nil)
        }

        await runner.run("PermissionService ignores speech when not required") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(service.hasRequiredPermissions(speechRequired: false))
        }

        await runner.run("PermissionService requires speech when requested") {
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

        await runner.run("PermissionService requests undetermined microphone") {
            let access = FakePermissionAccess(statuses: [.microphone: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("PermissionService opens denied microphone settings") {
            let access = FakePermissionAccess(statuses: [.microphone: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 0)
            try expect(access.openedSettings == [.microphone])
        }

        await runner.run("PermissionService requests undetermined speech recognition") {
            let access = FakePermissionAccess(statuses: [.speechRecognition: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .speechRecognition)

            try expect(access.requestedSpeechRecognitionCount == 1)
            try expect(access.openedSettings.isEmpty)
        }

        await runner.run("PermissionService opens accessibility settings") {
            let access = FakePermissionAccess(statuses: [.accessibility: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .accessibility)

            try expect(access.openedSettings == [.accessibility])
        }

        await runner.run("ASREngineProvider shares Speech and Apple engines") {
            let provider = ASREngineProvider()
            let speechRecognizer = provider.speechRecognizer()
            let appleEngine = provider.appleEngine()

            try expect(speechRecognizer === provider.speechRecognizer())
            try expect(appleEngine === provider.appleEngine())
            try expect(appleEngine.recognizer === speechRecognizer)
        }

        await runner.run("ASREngineProvider releases Sherpa engine without loading model") {
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

        await runner.run("ASREngineProvider shares Volcengine engine") {
            let provider = ASREngineProvider()
            let engine = provider.volcengineEngine()

            try expect(engine === provider.volcengineEngine())
        }

        runner.finish()
    }
}

private struct TestRunner {
    private var failures: [String] = []

    mutating func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("All architecture tests passed")
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
