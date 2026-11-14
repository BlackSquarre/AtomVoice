import Foundation

/// 仅隔离系统 WebSocket，离线测试与生产使用相同发送泵和事件状态。
protocol OpenAITranscriptionTransport: AnyObject {
    var httpStatusCode: Int? { get }
    func resume()
    func send(_ message: String, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<Data, Error>) -> Void)
    func cancel()
}

private final class OpenAIURLSessionTransport: OpenAITranscriptionTransport {
    private let task: URLSessionWebSocketTask
    init(session: URLSession, request: URLRequest) { task = session.webSocketTask(with: request) }
    var httpStatusCode: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    func resume() { task.resume() }
    func send(_ message: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(message), completionHandler: completion)
    }
    func receive(completion: @escaping (Result<Data, Error>) -> Void) {
        task.receive { result in
            completion(result.map { message in
                switch message {
                case .string(let text): return Data(text.utf8)
                case .data(let data): return data
                @unknown default: return Data()
                }
            })
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// 一轮一个连接、一个最终 commit；状态与发送完成均回到同一串行 owner。
final class OpenAITranscriptionConnection: CloudASRConnection {
    weak var delegate: CloudASRConnectionDelegate?
    private let transport: OpenAITranscriptionTransport
    private let configuration: OpenAIASRConfiguration
    private let queue = DispatchQueue(label: "com.atomvoice.openaiASR.connection")
    private enum Command { case audio(Data), commit }
    private var pending: [Command] = []
    private var sending = false
    private var started = false
    private var ready = false
    private var ended = false
    private var finalRequested = false
    private var commitSent = false
    private var audioBytes = 0
    private var committedItemID: String?
    private var transcript = OpenAITranscriptionTranscript()
    private var seenEvents = Set<String>()

    convenience init(session: URLSession, request: URLRequest, configuration: OpenAIASRConfiguration) {
        self.init(transport: OpenAIURLSessionTransport(session: session, request: request),
                  configuration: configuration)
    }

    init(transport: OpenAITranscriptionTransport, configuration: OpenAIASRConfiguration) {
        self.transport = transport
        self.configuration = configuration
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.ended else { return }
            self.started = true
            self.transport.resume()
            self.receiveNext()
            do {
                let message = try OpenAITranscriptionCodec.sessionUpdate(self.configuration)
                self.sending = true
                self.transport.send(message) { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.ended else { return }
                        self.sending = false
                        if error != nil { self.failTransport(); return }
                        self.pump()
                    }
                }
            } catch {
                self.fail(.init(kind: .protocolMessage, message: loc("openai.error.protocol")))
            }
        }
    }

    func sendAudioChunk(_ data: Data, isFinal: Bool) {
        queue.async { [weak self] in
            guard let self, !self.ended, !self.finalRequested else { return }
            guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                self.fail(.init(kind: .protocolMessage, message: loc("openai.error.protocol")))
                return
            }
            if !data.isEmpty {
                self.pending.append(.audio(data))
                self.audioBytes += data.count
            }
            if isFinal {
                self.finalRequested = true
                if self.audioBytes == 0 {
                    self.finish(text: "")
                    return
                }
                self.pending.append(.commit)
            }
            self.pump()
        }
    }

    func cancel() {
        // 调用方取消后会立即释放连接，必须让清理闭包持有自己直到 socket 已关闭。
        queue.async { self.end() }
    }

    private func pump() {
        guard ready, !ended, !sending, !pending.isEmpty else { return }
        // 出队后立即释放原始 PCM，不额外保留整轮已发送音频。
        let command = pending.removeFirst()
        do {
            let message: String
            switch command {
            case .audio(let data): message = try OpenAITranscriptionCodec.append(data)
            case .commit:
                commitSent = true
                message = try OpenAITranscriptionCodec.commit()
            }
            sending = true
            transport.send(message) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.ended else { return }
                    self.sending = false
                    if error != nil { self.failTransport(); return }
                    self.pump()
                }
            }
        } catch {
            fail(.init(kind: .protocolMessage, message: loc("openai.error.protocol")))
        }
    }

    private func receiveNext() {
        guard !ended else { return }
        transport.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.ended else { return }
                switch result {
                case .success(let data):
                    do { try self.handle(OpenAITranscriptionCodec.decode(data)) }
                    catch { self.fail(.init(kind: .protocolMessage, message: loc("openai.error.protocol"))) }
                    if !self.ended { self.receiveNext() }
                case .failure: self.failTransport()
                }
            }
        }
    }

    private func handle(_ event: [String: Any]) throws {
        guard let type = event["type"] as? String else { throw OpenAITranscriptionCodec.InvalidEvent() }
        if let eventID = event["event_id"] as? String, !seenEvents.insert(eventID).inserted { return }
        switch type {
        case "session.updated":
            guard !ready else { return }
            guard OpenAITranscriptionCodec.isExpectedSession(event["session"], expectedModel: configuration.resolvedModel) else {
                fail(.init(kind: .protocolMessage, message: loc("openai.error.invalidSession")))
                return
            }
            ready = true
            delegate?.connectionDidOpen(self)
            pump()
        case "input_audio_buffer.committed":
            guard commitSent, let itemID = event["item_id"] as? String,
                  committedItemID == nil || committedItemID == itemID else {
                throw OpenAITranscriptionCodec.InvalidEvent()
            }
            committedItemID = itemID
            emit(itemID: itemID)
        case "conversation.item.input_audio_transcription.delta":
            let itemID = try transcript.apply(event, final: false)
            emit(itemID: itemID)
        case "conversation.item.input_audio_transcription.completed":
            let itemID = try transcript.apply(event, final: true)
            emit(itemID: itemID)
        case "conversation.item.input_audio_transcription.failed", "error":
            fail(OpenAITranscriptionCodec.failure(event["error"] as? [String: Any]))
        default: break
        }
    }

    private func emit(itemID: String) {
        // 只有本轮 commit 确认的 item 可以结束本轮；早到的 delta/final 先暂存。
        if let committedItemID {
            guard itemID == committedItemID else { return }
            if finalRequested && transcript.isFinal(itemID: itemID) {
                finish(text: transcript.text(itemID: itemID))
                return
            }
        }
        delegate?.connection(self, didReceiveText: transcript.text(itemID: committedItemID ?? itemID), isFinal: false)
    }

    private func finish(text: String) {
        guard !ended else { return }
        delegate?.connection(self, didReceiveText: text, isFinal: true)
        end()
    }

    private func failTransport() {
        fail(OpenAITranscriptionCodec.failure(nil, statusCode: transport.httpStatusCode))
    }

    private func fail(_ error: CloudASRFailure) {
        guard !ended else { return }
        delegate?.connection(self, didFailWithError: error)
        end()
    }

    private func end() {
        guard !ended else { return }
        ended = true
        pending.removeAll()
        transcript = .init()
        seenEvents.removeAll()
        transport.cancel()
    }
}

/// 字段使用系统 JSON 编码，服务器的 message/音频/文字不会混入错误文案。
enum OpenAITranscriptionCodec {
    struct InvalidEvent: Error {}

    static func sessionUpdate(_ configuration: OpenAIASRConfiguration) throws -> String {
        var transcription: [String: Any] = ["model": configuration.resolvedModel.rawValue]
        switch configuration.resolvedModel {
        case .live:
            if !configuration.languages.isEmpty { transcription["languages"] = configuration.languages }
            if !configuration.prompt.isEmpty { transcription["prompt"] = configuration.prompt }
            if !configuration.keywords.isEmpty { transcription["keywords"] = configuration.keywords }
        case .whisper:
            if let language = configuration.languages.first { transcription["language"] = language }
        }
        if let delay = configuration.delay { transcription["delay"] = delay }
        return try encode([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ]],
            ],
        ])
    }

    static func append(_ data: Data) throws -> String {
        try encode(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }
    static func commit() throws -> String { try encode(["type": "input_audio_buffer.commit"]) }
    private static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InvalidEvent() }
        return event
    }
    static func isExpectedSession(_ value: Any?, expectedModel: OpenAIASRModel = .live) -> Bool {
        guard let session = value as? [String: Any], session["type"] as? String == "transcription",
              let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any],
              let transcription = input["transcription"] as? [String: Any],
              transcription["model"] as? String == expectedModel.rawValue,
              let format = input["format"] as? [String: Any],
              format["type"] as? String == "audio/pcm", format["rate"] as? Int == 24_000 else { return false }
        return input["turn_detection"] == nil || input["turn_detection"] is NSNull
    }

    static func failure(_ error: [String: Any]?, statusCode: Int? = nil) -> CloudASRFailure {
        let code = error?["code"] as? String ?? ""
        let type = error?["type"] as? String ?? ""
        let key: String
        switch code {
        case "invalid_api_key", "invalid_authentication", "authentication_error": key = "openai.error.unauthorized"
        case "unsupported_country_region_territory", "permission_denied", "model_not_found": key = "openai.error.accessDenied"
        case "insufficient_quota", "billing_hard_limit_reached", "quota_exceeded": key = "openai.error.quota"
        case "rate_limit_exceeded", "slow_down": key = "openai.error.rateLimit"
        default:
            switch statusCode {
            case 401: key = "openai.error.unauthorized"
            case 403: key = "openai.error.accessDenied"
            case 429: key = "openai.error.rateLimit"
            default: key = type == "invalid_request_error" ? "openai.error.configuration" : (error == nil ? "openai.error.transport" : "openai.error.server")
            }
        }
        return .init(kind: error == nil ? .transport : .server, message: loc(key))
    }
}

/// 服务端最终文字替换临时累计；按 item/content 隔离，完成后忽略迟到 delta。
struct OpenAITranscriptionTranscript {
    private struct Part { var text = ""; var final = false }
    private var items: [String: [Int: Part]] = [:]

    mutating func apply(_ event: [String: Any], final: Bool) throws -> String {
        guard let itemID = event["item_id"] as? String, !itemID.isEmpty else { throw OpenAITranscriptionCodec.InvalidEvent() }
        let index = event["content_index"] as? Int ?? 0
        guard index >= 0, let value = event[final ? "transcript" : "delta"] as? String else {
            throw OpenAITranscriptionCodec.InvalidEvent()
        }
        var part = items[itemID]?[index] ?? Part()
        if !part.final {
            if final { part.text = value; part.final = true }
            else { part.text += value }
            items[itemID, default: [:]][index] = part
        }
        return itemID
    }
    func text(itemID: String) -> String {
        guard let parts = items[itemID] else { return "" }
        return parts.keys.sorted().map { parts[$0]!.text }.joined()
    }
    func isFinal(itemID: String) -> Bool {
        guard let parts = items[itemID], !parts.isEmpty else { return false }
        return parts.values.allSatisfy(\.final)
    }
}
