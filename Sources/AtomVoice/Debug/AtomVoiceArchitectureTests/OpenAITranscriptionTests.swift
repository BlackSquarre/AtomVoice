import Foundation
@testable import AtomVoiceCore

enum OpenAITranscriptionTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("OpenAI configuration uses transcription session and JSON-escaped context") {
            let configuration = OpenAIASRConfiguration(delay: "low", languages: ["zh-cn", "en"],
                prompt: "fixture \"context\"\nline", keywords: ["fixture\\term"])
            let event = try OpenAITranscriptionCodec.decode(Data(OpenAITranscriptionCodec.sessionUpdate(configuration).utf8))
            let session = try require(event["session"] as? [String: Any])
            let input = try require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
            let transcription = try require(input["transcription"] as? [String: Any])
            try expect(event["type"] as? String == "session.update")
            try expect(session["type"] as? String == "transcription")
            try expect(input["turn_detection"] is NSNull)
            try expect(transcription["model"] as? String == "gpt-live-transcribe")
            try expect(transcription["prompt"] as? String == configuration.prompt)
            try expect(transcription["keywords"] as? [String] == configuration.keywords)
            try expect(OpenAITranscriptionCodec.isExpectedSession(session))
        }
        await runner.run("OpenAI Whisper sends only its supported single-language transcription fields") {
            var configuration = OpenAIASRConfiguration(delay: "low", languages: ["zh"],
                prompt: "retained live context", keywords: ["retained live keyword"])
            configuration.model = .whisper
            let event = try sessionEvent(configuration: configuration)
            let session = try require(event["session"] as? [String: Any])
            let input = try require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
            let transcription = try require(input["transcription"] as? [String: Any])
            try expect(transcription["model"] as? String == "gpt-realtime-whisper")
            try expect(transcription["language"] as? String == "zh")
            try expect(transcription["delay"] as? String == "low")
            try expect(transcription["languages"] == nil && transcription["prompt"] == nil && transcription["keywords"] == nil)
            try expect(Set(transcription.keys) == ["model", "language", "delay"])
            try expect(input["turn_detection"] is NSNull)
            try expect(OpenAITranscriptionCodec.isExpectedSession(session, expectedModel: .whisper))
            try expect(!OpenAITranscriptionCodec.isExpectedSession(session, expectedModel: .live))
        }
        await runner.run("OpenAI connection accepts only the model frozen for that recording") {
            var configuration = OpenAIASRConfiguration()
            configuration.model = .whisper
            let matching = OpenAITranscriptionFixture(autoCompleteSends: true, configuration: configuration)
            try await matching.open()
            try expect(matching.recorder.opens == 1 && matching.recorder.errors.isEmpty)
            matching.connection.cancel()
            let mismatched = OpenAITranscriptionFixture(autoCompleteSends: true, configuration: configuration)
            mismatched.connection.resume()
            try await waitForAsyncCallbacks()
            mismatched.transport.deliver(try sessionEvent())
            try await waitForAsyncCallbacks()
            try expect(mismatched.recorder.opens == 0 && mismatched.recorder.errors.count == 1)
        }
        await runner.run("OpenAI catalog filters task-incompatible names and keeps stable deduplicated model order") {
            let body = Data(#"{"data":[{"id":"gpt-realtime-whisper"},{"id":"gpt-live-transcribe"},{"id":"gpt-live-transcribe"},{"id":"gpt-transcribe"},{"id":"gpt-realtime-2.1"},{"id":"gpt-4o-transcribe"},{"id":"gpt-live-transcribe-unknown-snapshot"},{"id":"tts-1"}]}"#.utf8)
            let models = try OpenAIASRModelCatalog.decode(body)
            try expect(models == [.live, .whisper])
        }
        await runner.run("OpenAI catalog excludes shutdown models at the UTC date boundary") {
            let body = Data(#"{"data":[{"id":"gpt-live-transcribe","shutdown_date":"2026-11-13"},{"id":"gpt-realtime-whisper","shutdown_date":"2026-11-14"}]}"#.utf8)
            let day = try require(ISO8601DateFormatter().date(from: "2026-11-13T00:00:00Z"))
            let beforeShutdown = try OpenAIASRModelCatalog.decode(body, now: day.addingTimeInterval(-1))
            let atShutdown = try OpenAIASRModelCatalog.decode(body, now: day)
            let afterShutdown = try OpenAIASRModelCatalog.decode(body, now: day.addingTimeInterval(86_400))
            try expect(beforeShutdown == [.live, .whisper])
            try expect(atShutdown == [.whisper])
            try expect(afterShutdown.isEmpty)
        }
        await runner.run("OpenAI catalog distinguishes an empty compatible list from malformed responses") {
            let empty = try OpenAIASRModelCatalog.decode(Data(#"{"data":[]}"#.utf8))
            try expect(empty.isEmpty)
            let incomplete = Data(#"{"data":[{"id":"gpt-live-transcribe","shutdown_date":"invalid-date"},{"id":"gpt-realtime-whisper","shutdown_date":null}]}"#.utf8)
            let available = try OpenAIASRModelCatalog.decode(incomplete)
            try expect(available == [.whisper])
            do {
                _ = try OpenAIASRModelCatalog.decode(Data(#"{"error":{"message":"fixture raw body"}}"#.utf8))
                throw OpenAITranscriptionTestError.fixture
            } catch let error as CloudASRFailure {
                try expect(error.kind == .protocolMessage && !error.message.contains("fixture raw"))
            }
        }
        await runner.run("OpenAI catalog fetch uses the official GET and maps HTTP failures without response leakage") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OpenAICatalogURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); OpenAICatalogURLProtocol.setHandler(nil) }
            let catalog = OpenAIASRModelCatalog(session: session)
            OpenAICatalogURLProtocol.setHandler { request in
                try expect(request.httpMethod == "GET")
                try expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-offline")
                return (200, Data(#"{"data":[{"id":"gpt-realtime-whisper"}]}"#.utf8))
            }
            let models = try await catalog.fetch(apiKey: " fixture-offline ")
            try expect(models == [.whisper])
            OpenAICatalogURLProtocol.setHandler { _ in
                (429, Data(#"{"error":{"code":"insufficient_quota","message":"fixture secret server body"}}"#.utf8))
            }
            do {
                _ = try await catalog.fetch(apiKey: "fixture-offline")
                throw OpenAITranscriptionTestError.fixture
            } catch let error as CloudASRFailure {
                try expect(error.message == loc("openai.error.quota"))
                try expect(!error.message.contains("fixture secret"))
            }
        }
        await runner.run("OpenAI provider freezes one key snapshot and declares 24k PCM") {
            var reads = 0
            let provider = OpenAITranscriptionProvider(snapshot: {
                reads += 1
                return .init(apiKey: "fixture-offline", configuration: .init())
            })
            guard case .success(let connection) = provider.prepareConnection() else { throw OpenAITranscriptionTestError.fixture }
            try expect(reads == 1)
            try expect(provider.audioConfiguration.sampleRate == 24_000)
            try expect(provider.audioConfiguration.byteCount(duration: 0.1) == 4_800)
            try expect(provider.requiresFinalConfirmation)
            connection.cancel()
        }
        await runner.run("OpenAI provider distinguishes failed key read without opening a socket") {
            let provider = OpenAITranscriptionProvider(snapshot: { throw OpenAIASRSettingsError.keychainUnavailable })
            guard case .failure(let error) = provider.prepareConnection() else { throw OpenAITranscriptionTestError.fixture }
            try expect(error.kind == .configuration)
        }
        await runner.run("OpenAI sends audio only after configuration ack and commits after send drain") {
            let fixture = OpenAITranscriptionFixture()
            fixture.connection.resume()
            fixture.connection.sendAudioChunk(Data([1, 2, 3, 4]), isFinal: false)
            fixture.connection.sendAudioChunk(Data([5, 6]), isFinal: true)
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types == ["session.update"])
            try expect(fixture.recorder.opens == 0)
            fixture.transport.deliver(try sessionEvent())
            try await waitForAsyncCallbacks()
            try expect(fixture.recorder.opens == 1)
            try expect(fixture.transport.types == ["session.update"])
            fixture.transport.completeSend()
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types == ["session.update", "input_audio_buffer.append"])
            let firstAudio = try require(fixture.transport.events.last?["audio"] as? String)
            try expect(Data(base64Encoded: firstAudio) == Data([1, 2, 3, 4]))
            fixture.transport.completeSend()
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types.last == "input_audio_buffer.append")
            fixture.transport.completeSend()
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types == ["session.update", "input_audio_buffer.append", "input_audio_buffer.append", "input_audio_buffer.commit"])
            fixture.connection.cancel()
        }
        await runner.run("OpenAI accumulates deltas, ignores duplicate events, and replaces partial with final") {
            let fixture = OpenAITranscriptionFixture(autoCompleteSends: true)
            try await fixture.open()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-a", "event_id": "delta-1", "delta": "hello "])
            try await waitForAsyncCallbacks()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-a", "event_id": "delta-1", "delta": "hello "])
            try await waitForAsyncCallbacks()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.delta", "item_id": "item-a", "delta": "world"])
            try await waitForAsyncCallbacks()
            try expect(fixture.recorder.results.map(\.0) == ["hello ", "hello world"])
            fixture.connection.sendAudioChunk(Data(repeating: 0, count: 4_800), isFinal: true)
            try await waitForAsyncCallbacks()
            fixture.transport.deliver(["type": "input_audio_buffer.committed", "item_id": "item-a"])
            try await waitForAsyncCallbacks()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-a", "transcript": "Hello, world!"])
            try await waitForAsyncCallbacks()
            try expect(fixture.recorder.results.last?.0 == "Hello, world!")
            try expect(fixture.recorder.results.filter(\.1).count == 1)
            try expect(fixture.transport.cancels == 1)
        }
        await runner.run("OpenAI item completion before commit ack cannot finish the wrong turn") {
            let fixture = OpenAITranscriptionFixture(autoCompleteSends: true)
            try await fixture.open()
            fixture.connection.sendAudioChunk(Data(repeating: 0, count: 4_800), isFinal: true)
            try await waitForAsyncCallbacks()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "other-item", "transcript": "other"])
            try await waitForAsyncCallbacks()
            try expect(!fixture.recorder.results.contains(where: \.1))
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "own-item", "transcript": "own"])
            try await waitForAsyncCallbacks()
            try expect(!fixture.recorder.results.contains(where: \.1))
            fixture.transport.deliver(["type": "input_audio_buffer.committed", "item_id": "own-item"])
            try await waitForAsyncCallbacks()
            try expect(fixture.recorder.results.filter(\.1).map(\.0) == ["own"])
        }
        await runner.run("OpenAI empty tail still commits audio already appended") {
            let fixture = OpenAITranscriptionFixture(autoCompleteSends: true)
            try await fixture.open()
            fixture.connection.sendAudioChunk(Data(repeating: 0, count: 4_800), isFinal: false)
            fixture.connection.sendAudioChunk(Data(), isFinal: true)
            fixture.connection.sendAudioChunk(Data(), isFinal: true)
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types.filter { $0 == "input_audio_buffer.commit" }.count == 1)
            fixture.connection.cancel()
        }
        await runner.run("OpenAI zero audio finishes empty without sending an empty commit") {
            let fixture = OpenAITranscriptionFixture(autoCompleteSends: true)
            try await fixture.open()
            fixture.connection.sendAudioChunk(Data(), isFinal: true)
            try await waitForAsyncCallbacks()
            try expect(!fixture.transport.types.contains("input_audio_buffer.commit"))
            try expect(fixture.recorder.results.filter(\.1).map(\.0) == [""])
        }
        await runner.run("OpenAI cancel discards queued audio and late transcript callbacks") {
            let fixture = OpenAITranscriptionFixture()
            fixture.connection.resume()
            fixture.connection.sendAudioChunk(Data(repeating: 0, count: 4_800), isFinal: true)
            try await waitForAsyncCallbacks()
            fixture.connection.cancel()
            try await waitForAsyncCallbacks()
            fixture.transport.completeSend()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "late", "transcript": "late"])
            try await waitForAsyncCallbacks()
            try expect(fixture.transport.types == ["session.update"])
            try expect(fixture.recorder.results.isEmpty)
            try expect(fixture.recorder.errors.isEmpty)
        }
        await runner.run("OpenAI cancellation closes transport even when owner releases immediately") {
            let transport = OpenAITranscriptionFakeTransport(autoCompleteSends: false)
            var connection: OpenAITranscriptionConnection? = .init(transport: transport, configuration: .init())
            weak var releasedConnection = connection
            connection?.resume()
            try await waitForAsyncCallbacks()
            connection?.cancel()
            connection = nil
            try await waitForAsyncCallbacks()
            try expect(transport.cancels == 1)
            try expect(releasedConnection == nil)
        }
        await runner.run("OpenAI invalid session and send failure each terminate once") {
            let invalid = OpenAITranscriptionFixture(autoCompleteSends: true)
            invalid.connection.resume()
            try await waitForAsyncCallbacks()
            invalid.transport.deliver(["type": "session.updated", "session": ["type": "realtime"]])
            try await waitForAsyncCallbacks()
            try expect(invalid.recorder.opens == 0 && invalid.recorder.errors.count == 1)
            let failed = OpenAITranscriptionFixture()
            failed.connection.resume()
            try await waitForAsyncCallbacks()
            failed.transport.completeSend(error: OpenAITranscriptionTestError.fixture)
            try await waitForAsyncCallbacks()
            failed.transport.failReceive()
            try await waitForAsyncCallbacks()
            try expect(failed.recorder.errors.count == 1 && failed.transport.cancels == 1)
        }
        await runner.run("OpenAI protocol failures map codes without leaking raw server messages") {
            for code in ["invalid_api_key", "unsupported_country_region_territory", "insufficient_quota", "rate_limit_exceeded", "fixture-unknown"] {
                let failure = OpenAITranscriptionCodec.failure(["code": code, "message": "fixture secret transcript"])
                try expect(!failure.message.contains("fixture secret"))
            }
            let fixture = OpenAITranscriptionFixture(autoCompleteSends: true)
            try await fixture.open()
            fixture.transport.deliver(["type": "conversation.item.input_audio_transcription.failed", "item_id": "item-a", "error": ["code": "audio_unintelligible", "message": "fixture secret"]])
            try await waitForAsyncCallbacks()
            try expect(fixture.recorder.errors.count == 1)
            try expect(!fixture.recorder.errors[0].message.contains("fixture secret"))
        }
    }

    private static func sessionEvent(configuration: OpenAIASRConfiguration = .init()) throws -> [String: Any] {
        var event = try OpenAITranscriptionCodec.decode(Data(OpenAITranscriptionCodec.sessionUpdate(configuration).utf8))
        event["type"] = "session.updated"
        return event
    }
}

private enum OpenAITranscriptionTestError: Error { case fixture }

private final class OpenAICatalogURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?

    static func setHandler(_ value: ((URLRequest) throws -> (Int, Data))?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.lock.withLock { Self.handler }
            guard let callback else { throw OpenAITranscriptionTestError.fixture }
            let (status, body) = try callback(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else {
                throw OpenAITranscriptionTestError.fixture
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class OpenAITranscriptionFixture {
    let transport: OpenAITranscriptionFakeTransport
    let connection: OpenAITranscriptionConnection
    let recorder = OpenAITranscriptionRecorder()
    private let configuration: OpenAIASRConfiguration
    init(autoCompleteSends: Bool = false, configuration: OpenAIASRConfiguration = .init()) {
        self.configuration = configuration
        transport = OpenAITranscriptionFakeTransport(autoCompleteSends: autoCompleteSends)
        connection = OpenAITranscriptionConnection(transport: transport, configuration: configuration)
        connection.delegate = recorder
    }
    func open() async throws {
        connection.resume()
        try await waitForAsyncCallbacks()
        var event = try OpenAITranscriptionCodec.decode(Data(OpenAITranscriptionCodec.sessionUpdate(configuration).utf8))
        event["type"] = "session.updated"
        transport.deliver(event)
        try await waitForAsyncCallbacks()
    }
}

private final class OpenAITranscriptionRecorder: CloudASRConnectionDelegate {
    private let lock = NSLock()
    private var openCount = 0
    private var values: [(String, Bool)] = []
    private var failures: [CloudASRFailure] = []
    var opens: Int { lock.withLock { openCount } }
    var results: [(String, Bool)] { lock.withLock { values } }
    var errors: [CloudASRFailure] { lock.withLock { failures } }
    func connectionDidOpen(_ connection: any CloudASRConnection) { lock.withLock { openCount += 1 } }
    func connection(_ connection: any CloudASRConnection, didReceiveText text: String, isFinal: Bool) {
        lock.withLock { values.append((text, isFinal)) }
    }
    func connection(_ connection: any CloudASRConnection, didFailWithError error: CloudASRFailure) {
        lock.withLock { failures.append(error) }
    }
}

private final class OpenAITranscriptionFakeTransport: OpenAITranscriptionTransport {
    let httpStatusCode: Int? = nil
    private let lock = NSLock()
    private let autoCompleteSends: Bool
    private var sent: [[String: Any]] = []
    private var sendCallbacks: [(Error?) -> Void] = []
    private var receiveCallback: ((Result<Data, Error>) -> Void)?
    private var cancelCount = 0
    var events: [[String: Any]] { lock.withLock { sent } }
    var types: [String] { events.compactMap { $0["type"] as? String } }
    var cancels: Int { lock.withLock { cancelCount } }
    init(autoCompleteSends: Bool) { self.autoCompleteSends = autoCompleteSends }
    func resume() {}
    func send(_ message: String, completion: @escaping (Error?) -> Void) {
        lock.withLock {
            sent.append((try? OpenAITranscriptionCodec.decode(Data(message.utf8))) ?? [:])
            if !autoCompleteSends { sendCallbacks.append(completion) }
        }
        if autoCompleteSends { completion(nil) }
    }
    func receive(completion: @escaping (Result<Data, Error>) -> Void) {
        lock.withLock { receiveCallback = completion }
    }
    func cancel() { lock.withLock { cancelCount += 1 } }
    func completeSend(error: Error? = nil) {
        let callback = lock.withLock { sendCallbacks.isEmpty ? nil : sendCallbacks.removeFirst() }
        callback?(error)
    }
    func deliver(_ event: [String: Any]) {
        let callback = lock.withLock { let value = receiveCallback; receiveCallback = nil; return value }
        callback?(.success((try? JSONSerialization.data(withJSONObject: event)) ?? Data()))
    }
    func failReceive() {
        let callback = lock.withLock { let value = receiveCallback; receiveCallback = nil; return value }
        callback?(.failure(OpenAITranscriptionTestError.fixture))
    }
}
