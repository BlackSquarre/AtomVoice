import AVFoundation
import Foundation
@testable import AtomVoiceCore

enum ASRBoundaryTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Cloud configuration drives PCM conversion and packet duration") {
            let configuration = CloudASRAudioConfiguration(sampleRate: 8_000)
            let settings = VolcengineASRSettings(endpoint: "wss://fixture.invalid", apiKey: "fixture", resourceID: "fixture",
                enableITN: true, enableDDC: false, enableNonstream: false, selectedLanguage: "en-US")
            let payload = settings.requestPayload(audioConfiguration: configuration)
            try expect((payload["audio"] as? [String: Any])?["rate"] as? Int == 8_000)
            let connection = BoundaryCloudConnection()
            let controller = CloudASRRecognizerController(provider: BoundaryCloudProvider(connection: connection, configuration: configuration))
            try expect(controller.preferredAudioFormat == .init(sampleRate: 8_000, channelCount: 1))
            try expect(controller.start(onResult: { _, _ in }, onError: { _ in }) == nil)
            try await waitForAsyncCallbacks()
            connection.open()
            try await waitForAsyncCallbacks()
            let buffer = try require(makePCMBuffer(sampleRate: 8_000, frameLength: 800, fillValue: 0.25))
            controller.accept(buffer: buffer)
            try await waitForAsyncCallbacks()
            try expect(connection.sentFrames.count == 1)
            try expect(connection.sentFrames[0].0.count == 1_600 && !connection.sentFrames[0].1)
            controller.cancel()
        }
        await runner.run("Cloud stop before open keeps final completion unique and ignores late final") {
            let connection = BoundaryCloudConnection()
            let controller = CloudASRRecognizerController(provider: BoundaryCloudProvider(connection: connection))
            _ = controller.start(onResult: { _, _ in }, onError: { _ in })
            try await waitForAsyncCallbacks()
            controller.accept(buffer: try require(makePCMBuffer(sampleRate: 16_000, frameLength: 1_600)))
            var results: [String] = []
            controller.stop { text, _ in results.append(text) }
            try await waitForAsyncCallbacks()
            try expect(results.isEmpty)
            connection.open()
            try await waitForAsyncCallbacks()
            try expect(connection.sentFrames.contains { $0.1 })
            connection.emit("fixture", final: true)
            connection.emit("late", final: true)
            try await waitForAsyncCallbacks()
            try expect(results == ["fixture"])
            try expect(connection.cancelCount == 1)
        }
        await runner.run("Cloud transport classification retains existing benign socket compatibility") {
            try expect(CloudASRFailure(kind: .transport, message: "Socket is not connected").isBenignSocketClosure)
            try expect(CloudASRFailure(kind: .transport, message: "socket 未连接").isBenignSocketClosure)
            try expect(!CloudASRFailure(kind: .server, message: "invalid credentials").isBenignSocketClosure)
        }
        await runner.run("Controller routes the session format to actual buffered consumer") {
            let settings = RecordingSessionTestSettings()
            settings.apply()
            defer { settings.restore() }
            let session = FakeRecognitionSession(preferredAudioFormat: .init(sampleRate: 8_000, channelCount: 1))
            session.connectsAudioInput = true
            let harness = RecordingSessionHarness(session: session)
            defer { harness.tearDown() }
            harness.controller.start()
            try await waitForAsyncCallbacks()
            harness.audioEngine.router.receive(try require(makePCMBuffer(sampleRate: 48_000, frameLength: 480)))
            try await waitForAsyncCallbacks()
            try expect(!session.receivedAudioBuffers.isEmpty)
            try expect(session.receivedAudioBuffers.allSatisfy { $0.format.sampleRate == 8_000 && $0.format.channelCount == 1 })
            harness.controller.cancel()
        }

    }
}

private final class BoundaryCloudProvider: CloudASRProvider {
    let engineCode = "boundary"
    let displayName = "fixture"
    let finalResultTimeout = 10.0
    let audioConfiguration: CloudASRAudioConfiguration
    let connection: BoundaryCloudConnection
    init(connection: BoundaryCloudConnection, configuration: CloudASRAudioConfiguration = .init()) {
        self.connection = connection
        audioConfiguration = configuration
    }
    func validateCredentials() -> String? { nil }
    func createConnection() -> CloudASRConnection? { connection }
}

private final class BoundaryCloudConnection: CloudASRConnection {
    weak var delegate: CloudASRConnectionDelegate?
    var sentFrames: [(Data, Bool)] = []
    var cancelCount = 0
    func resume() {}
    func sendAudioChunk(_ data: Data, isFinal: Bool) { sentFrames.append((data, isFinal)) }
    func cancel() { cancelCount += 1 }
    func open() { delegate?.connectionDidOpen(self) }
    func emit(_ text: String, final: Bool) { delegate?.connection(self, didReceiveText: text, isFinal: final) }
}
