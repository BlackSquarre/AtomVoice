import AVFoundation
import Foundation

// MARK: - 豆包流式 ASR 模型版本（X-Api-Resource-Id 取值，个人版按时长计费）
// (Doubao streaming ASR model versions — X-Api-Resource-Id values, duration-based pricing for personal use.)

enum DoubaoModelKind: CaseIterable {
    case v2   // 2.0，对应 volc.seedasr.sauc.duration
    case v1   // 1.0，对应 volc.bigasr.sauc.duration

    var resourceID: String {
        switch self {
        case .v2: return "volc.seedasr.sauc.duration"
        case .v1: return "volc.bigasr.sauc.duration"
        }
    }

    /// 把任意 resourceID 字符串映射回模型版本；未知值（例如手动填入的并发版）也归到对应版本里。
    /// (Map any resourceID string back to a model version; unknown variants like concurrent-billing fall through to their version.)
    static func from(resourceID: String) -> DoubaoModelKind {
        let normalized = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == v1.resourceID || normalized.contains("bigasr") {
            return .v1
        }
        return .v2
    }
}

// MARK: - 火山引擎豆包 ASR 设置

struct VolcengineASRSettings {
    static let engineCode = "doubao"
    private static let keychainService = "com.blacksquarre.AtomVoice.volcengineASR"
    private static let keychainAccount = "apiKey"

    var endpoint: String
    var apiKey: String
    var resourceID: String
    var enableITN: Bool
    var enableDDC: Bool
    var enableNonstream: Bool
    var selectedLanguage: String

    static var defaultEndpoint: String { "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async" }
    static var defaultResourceID: String { DoubaoModelKind.v2.resourceID }

    static var savedAPIKey: String {
        KeychainStore.string(service: keychainService, account: keychainAccount) ?? ""
    }

    static var hasAPIKey: Bool {
        !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func saveAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(service: keychainService, account: keychainAccount)
            return true
        }
        return KeychainStore.setString(trimmed, service: keychainService, account: keychainAccount)
    }

    static func load() -> VolcengineASRSettings {
        let backend = AppSettings.backend
        return VolcengineASRSettings(
            endpoint: backend.string(forKey: AppSettings.Keys.doubaoASREndpoint, default: defaultEndpoint),
            apiKey: savedAPIKey,
            resourceID: backend.string(forKey: AppSettings.Keys.doubaoASRResourceID, default: defaultResourceID),
            enableITN: backend.bool(forKey: AppSettings.Keys.doubaoASREnableITN, default: true),
            enableDDC: backend.bool(forKey: AppSettings.Keys.doubaoASREnableDDC, default: false),
            enableNonstream: backend.bool(forKey: AppSettings.Keys.doubaoASREnableNonstream, default: false),
            selectedLanguage: AppSettings.selectedLanguage
        )
    }

    func persistNonSecretFields() {
        let backend = AppSettings.backend
        backend.set(trimmedEndpoint, forKey: AppSettings.Keys.doubaoASREndpoint)
        backend.set(trimmedResourceID, forKey: AppSettings.Keys.doubaoASRResourceID)
        backend.set(enableITN, forKey: AppSettings.Keys.doubaoASREnableITN)
        backend.set(enableDDC, forKey: AppSettings.Keys.doubaoASREnableDDC)
        backend.set(enableNonstream, forKey: AppSettings.Keys.doubaoASREnableNonstream)
    }

    var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedResourceID: String {
        resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var volcengineLanguage: String {
        switch selectedLanguage {
        case "zh-CN", "zh-TW": return "zh-CN"
        case "en-US": return "en-US"
        case "ja-JP": return "ja-JP"
        case "ko-KR": return "ko-KR"
        case "es-ES": return "es-MX"
        case "fr-FR": return "fr-FR"
        case "de-DE": return "de-DE"
        default: return "zh-CN"
        }
    }

    var outputZhVariant: String? {
        selectedLanguage == "zh-TW" ? "traditional" : nil
    }

    var autoPunctuationEnabled: Bool {
        AppSettings.autoPunctuationEnabled
    }

    var endWindowSize: Int {
        guard AppSettings.silenceAutoStopEnabled else { return 600 }
        let durationMS = Int(AppSettings.silenceDuration * 1000)
        return min(3000, max(200, durationMS))
    }

    var finalResultTimeout: Double {
        enableNonstream ? 2.0 : 1.0
    }

    var validationError: String? {
        if trimmedAPIKey.isEmpty { return loc("doubao.error.missingApiKey") }
        if trimmedResourceID.isEmpty { return loc("doubao.error.missingResourceID") }
        guard let url = URL(string: trimmedEndpoint), url.scheme == "wss" else {
            return loc("doubao.error.invalidEndpoint")
        }
        return nil
    }

    var globalSummary: String {
        let language = AppSettings.displayName(forRecognitionLanguage: selectedLanguage)
        let punctuation = autoPunctuationEnabled ? loc("doubao.settings.globalOn") : loc("doubao.settings.globalOff")
        let delay = String(format: loc("doubao.settings.globalTimeoutValue"), Double(endWindowSize) / 1000.0)
        return loc("doubao.settings.globalSummary", language, punctuation, delay)
    }

    func requestPayload() -> [String: Any] {
        let audio: [String: Any] = [
            "format": "pcm",
            "codec": "raw",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
            "language": volcengineLanguage,
        ]

        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": enableITN,
            "enable_punc": autoPunctuationEnabled,
            "enable_ddc": enableDDC,
            "enable_nonstream": enableNonstream,
            "enable_accelerate_text": true,
            "accelerate_score": 10,
            "end_window_size": endWindowSize,
            "show_utterances": true,
            "result_type": "full",
        ]

        if let outputZhVariant {
            request["output_zh_variant"] = outputZhVariant
        }

        return [
            "user": [
                "uid": "atomvoice-macos",
                "platform": "macOS",
            ],
            "audio": audio,
            "request": request,
        ]
    }
}

// MARK: - 火山引擎豆包 ASR Provider

final class VolcengineASRProvider: CloudASRProvider {
    let engineCode = VolcengineASRSettings.engineCode
    let displayName = "豆包云端 ASR"

    /// 长生命周期的共享 URLSession：复用同一个 session 让 URLSession 内部可以做 TLS session
    /// resumption 与连接池缓存，第二次以后的 WebSocket 握手能省掉一次完整 TLS handshake。
    /// (Long-lived shared URLSession enables TLS session resumption + connection caching across
    /// successive WebSocket connections.)
    private let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()

    func validateCredentials() -> String? {
        VolcengineASRSettings.load().validationError
    }

    func createConnection() -> CloudASRConnection? {
        let settings = VolcengineASRSettings.load()
        guard let url = URL(string: settings.trimmedEndpoint) else { return nil }

        let requestID = UUID().uuidString
        let connectID = UUID().uuidString
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.addValue(settings.trimmedAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.addValue(settings.trimmedResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.addValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.addValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.addValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        guard let initialFrame = try? VolcengineASRProtocolCodec.makeFullClientRequest(payload: settings.requestPayload()) else {
            return nil
        }

        DebugLog.info("[VolcengineASR] create: request=\(requestID) connect=\(connectID)")

        return VolcengineASRConnection(session: sharedSession, request: request, initialFrame: initialFrame)
    }

    func showSettings() {
        // 由 AppDelegate 调用 DoubaoSettingsWindowController
    }

    var finalResultTimeout: Double {
        VolcengineASRSettings.load().finalResultTimeout
    }
}

// MARK: - 火山引擎豆包 ASR 连接

private final class VolcengineASRConnection: NSObject, CloudASRConnection {
    weak var delegate: CloudASRConnectionDelegate?
    private let session: URLSession
    private let request: URLRequest
    private var task: URLSessionWebSocketTask?
    private let initialFrame: Data
    private let queue = DispatchQueue(label: "com.atomvoice.volcengineASR.connection")
    private var isCancelled = false

    init(session: URLSession, request: URLRequest, initialFrame: Data) {
        self.session = session
        self.request = request
        self.initialFrame = initialFrame
        super.init()
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            // 在共享 session 上创建新 WebSocket task；通过 per-task delegate 监听 didOpen，
            // 不需要也不应该 invalidate 共享 session。
            // (Create a new task on the shared session; per-task delegate is supported on macOS 12+.)
            let task = self.session.webSocketTask(with: self.request)
            task.delegate = self
            self.task = task
            task.resume()
        }
    }
}

extension VolcengineASRConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DebugLog.info("[VolcengineASR] WebSocket connected, protocol=\(`protocol` ?? "nil")")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isCancelled else {
                webSocketTask.cancel(with: .goingAway, reason: nil)
                return
            }
            // 发送初始帧，然后通知 delegate 已就绪
            self.send(initialFrame) { [weak self] in
                guard let self else { return }
                guard !self.isCancelled else { return }
                self.receiveLoop()
                DispatchQueue.main.async {
                    self.delegate?.connectionDidOpen(self)
                }
            }
        }
    }

    func sendAudioChunk(_ data: Data, isFinal: Bool) {
        let frame = VolcengineASRProtocolCodec.makeAudioRequest(payload: data, isFinal: isFinal)
        queue.async { [weak self] in
            self?.send(frame)
        }
    }

    func cancel() {
        DebugLog.info("[VolcengineASR] Canceling connection")
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isCancelled = true
            // 只取消当前 task；session 由 provider 长期持有以复用 TLS。
            // (Only cancel the task; the session is owned by the provider for TLS reuse.)
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        guard !isCancelled, let task else { return }
        task.send(.data(data)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.isCancelled else { return }
                if let error {
                    DebugLog.error("[VolcengineASR] send error: \(error.localizedDescription)")
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
                    self.delegate?.connection(self, didFailWithError: loc("doubao.error.sendFailed", error.localizedDescription))
                    return
                }
                completion?()
            }
        }
    }

    private func receiveLoop() {
        guard !isCancelled, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.isCancelled else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if !self.isCancelled {
                        self.receiveLoop()
                    }
                case .failure(let error):
                    DebugLog.error("[VolcengineASR] receive error: \(error.localizedDescription)")
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
                    self.delegate?.connection(self, didFailWithError: loc("doubao.error.connectionFailed", error.localizedDescription))
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let text):
            delegate?.connection(self, didFailWithError: loc("doubao.error.server", text))
            return
        @unknown default:
            return
        }

        do {
            let response = try VolcengineASRProtocolCodec.parseServerMessage(data)
            if let errorMessage = response.errorMessage {
                delegate?.connection(self, didFailWithError: loc("doubao.error.server", errorMessage))
                return
            }
            if let text = response.text {
                delegate?.connection(self, didReceiveText: text, isFinal: response.isFinal)
            }
        } catch {
            delegate?.connection(self, didFailWithError: error.localizedDescription)
        }
    }
}

// MARK: - 火山二进制协议编解码器

private struct VolcengineASRResponse {
    let text: String?
    let isFinal: Bool
    let errorMessage: String?
}

private enum VolcengineASRProtocolCodec {
    private enum MessageType: UInt8 {
        case fullClientRequest = 0x1
        case audioOnlyRequest = 0x2
        case fullServerResponse = 0x9
        case errorResponse = 0xf
    }

    static func makeFullClientRequest(payload: [String: Any]) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return makeFrame(
            messageType: .fullClientRequest,
            flags: 0,
            serialization: 1,
            compression: 0,
            payload: payloadData
        )
    }

    static func makeAudioRequest(payload: Data, isFinal: Bool) -> Data {
        makeFrame(
            messageType: .audioOnlyRequest,
            flags: isFinal ? 2 : 0,
            serialization: 0,
            compression: 0,
            payload: payload
        )
    }

    static func parseServerMessage(_ data: Data) throws -> VolcengineASRResponse {
        debugFrame(data, context: "receive")
        guard data.count >= 4 else {
            debugInvalidFrame("too_short", data: data)
            return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
        }
        let headerSize = Int(data[0] & 0x0f) * 4
        debugHeader(data, headerSize: headerSize)
        guard headerSize >= 4, data.count >= headerSize else {
            debugInvalidFrame("bad_header", data: data)
            return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
        }

        let type = data[1] >> 4
        let flags = data[1] & 0x0f
        let compression = data[2] & 0x0f
        guard compression == 0 else { throw ParseError.unsupportedCompression }

        if type == MessageType.fullServerResponse.rawValue {
            let hasSequence = flags == 1 || flags == 3
            let payloadSizeOffset = headerSize + (hasSequence ? 4 : 0)
            guard data.count >= payloadSizeOffset + 4 else {
                debugInvalidFrame("missing_payload_size", data: data)
                return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
            }
            let payloadSize = Int(readUInt32BE(data, offset: payloadSizeOffset))
            let payloadStart = payloadSizeOffset + 4
            debugPayload(payloadSize: payloadSize, payloadStart: payloadStart, dataCount: data.count, flags: flags)
            guard data.count >= payloadStart + payloadSize else {
                debugInvalidFrame("payload_truncated", data: data)
                return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
            }
            let payload = data[payloadStart..<(payloadStart + payloadSize)]
            let parsed = parseResult(from: Data(payload))
            return VolcengineASRResponse(text: parsed.text, isFinal: flags == 2 || flags == 3 || parsed.isDefinite, errorMessage: nil)
        }

        if type == MessageType.errorResponse.rawValue {
            guard data.count >= headerSize + 8 else {
                debugInvalidFrame("bad_error_frame", data: data)
                return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
            }
            let code = readUInt32BE(data, offset: headerSize)
            let messageSize = Int(readUInt32BE(data, offset: headerSize + 4))
            let messageStart = headerSize + 8
            guard data.count >= messageStart + messageSize else {
                debugInvalidFrame("bad_error_payload", data: data)
                return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
            }
            let message = String(data: data[messageStart..<(messageStart + messageSize)], encoding: .utf8) ?? ""
            return VolcengineASRResponse(text: nil, isFinal: true, errorMessage: "\(code): \(message)")
        }

        return VolcengineASRResponse(text: nil, isFinal: false, errorMessage: nil)
    }

    #if DEBUG_BUILD
    private static func debugFrame(_ data: Data, context: String) {
        let prefix = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        DebugLog.debug("[VolcengineASR] [protocol] \(context) bytes=\(data.count) prefix=\(prefix)")
    }

    private static func debugHeader(_ data: Data, headerSize: Int) {
        guard data.count >= 4 else { return }
        let version = data[0] >> 4
        let type = data[1] >> 4
        let flags = data[1] & 0x0f
        let serialization = data[2] >> 4
        let compression = data[2] & 0x0f
        DebugLog.debug("[VolcengineASR] [protocol] header version=\(version) headerSize=\(headerSize) type=\(type) flags=\(flags) serialization=\(serialization) compression=\(compression)")
    }

    private static func debugPayload(payloadSize: Int, payloadStart: Int, dataCount: Int, flags: UInt8) {
        DebugLog.debug("[VolcengineASR] [protocol] payload flags=\(flags) start=\(payloadStart) size=\(payloadSize) dataCount=\(dataCount)")
    }

    private static func debugInvalidFrame(_ reason: String, data: Data) {
        let prefix = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        DebugLog.error("[VolcengineASR] [protocol] ignored invalid frame reason=\(reason) bytes=\(data.count) prefix=\(prefix)")
    }
    #else
    private static func debugFrame(_ data: Data, context: String) {}
    private static func debugHeader(_ data: Data, headerSize: Int) {}
    private static func debugPayload(payloadSize: Int, payloadStart: Int, dataCount: Int, flags: UInt8) {}
    private static func debugInvalidFrame(_ reason: String, data: Data) {}
    #endif

    private static func makeFrame(messageType: MessageType,
                                  flags: UInt8,
                                  serialization: UInt8,
                                  compression: UInt8,
                                  payload: Data) -> Data {
        var data = Data()
        data.append(0x11)
        data.append((messageType.rawValue << 4) | flags)
        data.append((serialization << 4) | compression)
        data.append(0x00)
        appendUInt32BE(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private static func parseResult(from payload: Data) -> (text: String?, isDefinite: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return (nil, false)
        }

        var resultText: String?
        var isDefinite = false

        if let result = json["result"] as? [String: Any],
           let text = result["text"] as? String,
           !text.isEmpty {
            resultText = text
            isDefinite = utterancesAreDefinite(result["utterances"])
        }

        if let resultList = json["result"] as? [[String: Any]],
           let text = resultList.compactMap({ $0["text"] as? String }).last,
           !text.isEmpty {
            resultText = text
            isDefinite = resultList.contains { utterancesAreDefinite($0["utterances"]) }
        }

        if resultText == nil,
           let text = json["text"] as? String,
           !text.isEmpty {
            resultText = text
        }

        return (resultText, isDefinite)
    }

    private static func utterancesAreDefinite(_ value: Any?) -> Bool {
        guard let utterances = value as? [[String: Any]] else { return false }
        return utterances.contains { ($0["definite"] as? Bool) == true }
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
        (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) |
        UInt32(data[offset + 3])
    }

    private enum ParseError: LocalizedError {
        case invalidFrame
        case unsupportedCompression

        var errorDescription: String? {
            switch self {
            case .invalidFrame: return loc("doubao.error.protocol")
            case .unsupportedCompression: return loc("doubao.error.unsupportedCompression")
            }
        }
    }
}
