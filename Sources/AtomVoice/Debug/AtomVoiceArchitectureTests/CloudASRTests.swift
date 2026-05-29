import Foundation
@testable import AtomVoiceCore

enum CloudASRTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Cloud ASR emits duplicate final text") {
            let connection = FakeCloudASRConnection()
            let provider = FakeCloudASRProvider(connection: connection)
            let controller = CloudASRRecognizerController(provider: provider)
            var results: [(String, Bool)] = []

            let error = controller.start(
                onResult: { text, isFinal in
                    results.append((text, isFinal))
                },
                onError: { _ in }
            )
            try expect(error == nil)
            try await waitForAsyncCallbacks()
            try expect(connection.didResume)

            connection.open()
            try await waitForAsyncCallbacks()

            connection.emit(text: "hello", isFinal: false)
            try await waitForAsyncCallbacks()
            connection.emit(text: "hello", isFinal: true)
            try await waitForAsyncCallbacks()

            try expect(results.count == 2)
            try expect(results[0].0 == "hello")
            try expect(results[0].1 == false)
            try expect(results[1].0 == "hello")
            try expect(results[1].1 == true)
            controller.cancel()
        }
    }
}

private final class FakeCloudASRProvider: CloudASRProvider {
    let engineCode = "fake-cloud"
    let displayName = "Fake Cloud"
    let finalResultTimeout = 0.1
    private let connection: FakeCloudASRConnection

    init(connection: FakeCloudASRConnection) {
        self.connection = connection
    }

    func validateCredentials() -> String? { nil }
    func createConnection() -> CloudASRConnection? { connection }
    func showSettings() {}
}

private final class FakeCloudASRConnection: CloudASRConnection {
    weak var delegate: CloudASRConnectionDelegate?
    private(set) var didResume = false
    private(set) var sentFrames: [(Data, Bool)] = []

    func resume() {
        didResume = true
    }

    func sendAudioChunk(_ data: Data, isFinal: Bool) {
        sentFrames.append((data, isFinal))
    }

    func cancel() {}

    func open() {
        delegate?.connectionDidOpen(self)
    }

    func emit(text: String, isFinal: Bool) {
        delegate?.connection(self, didReceiveText: text, isFinal: isFinal)
    }
}
