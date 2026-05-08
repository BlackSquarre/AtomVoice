import AVFoundation
import Foundation
import os.log

private let volcengineLogger = Logger(subsystem: "com.blacksquarre.AtomVoice", category: "VolcengineASR")

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
    static var defaultResourceID: String { "volc.seedasr.sauc.duration" }

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
        let defaults = UserDefaults.standard
        return VolcengineASRSettings(
            endpoint: defaults.string(forKey: "doubaoASREndpoint") ?? defaultEndpoint,
            apiKey: savedAPIKey,
            resourceID: defaults.string(forKey: "doubaoASRResourceID") ?? defaultResourceID,
            enableITN: defaults.object(forKey: "doubaoASREnableITN") as? Bool ?? true,
            enableDDC: defaults.object(forKey: "doubaoASREnableDDC") as? Bool ?? false,
            enableNonstream: defaults.object(forKey: "doubaoASREnableNonstream") as? Bool ?? false,
            selectedLanguage: defaults.string(forKey: "selectedLanguage") ?? "zh-CN"
        )
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
        UserDefaults.standard.bool(forKey: "autoPunctuationEnabled")
    }

    var endWindowSize: Int {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "silenceAutoStopEnabled") else { return 600 }
        let durationMS = Int(defaults.double(forKey: "silenceDuration") * 1000)
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

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)

        volcengineLogger.info("[create] request=\(requestID, privacy: .public) connect=\(connectID, privacy: .public)")

        return VolcengineASRConnection(session: session, task: task, initialFrame: initialFrame)
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
    private var session: URLSession
    private var task: URLSessionWebSocketTask
    private let initialFrame: Data
    private let queue = DispatchQueue(label: "com.atomvoice.volcengineASR.connection")
    private var isCancelled = false

    init(session: URLSession, task: URLSessionWebSocketTask, initialFrame: Data) {
        self.session = session
        self.task = task
        self.initialFrame = initialFrame
        super.init()
    }

    func resume() {
        let originalRequest = task.originalRequest!
        let oldSession = session
        let oldTask = task

        // 创建带 delegate 的新 session/task，用于监听 didOpen
        let delegateSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let delegateTask = delegateSession.webSocketTask(with: originalRequest)

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isCancelled else {
                delegateTask.cancel(with: .goingAway, reason: nil)
                delegateSession.invalidateAndCancel()
                return
            }
            // 替换为带 delegate 的版本，后续 send/receive 都走新 task
            oldTask.cancel(with: .goingAway, reason: nil)
            oldSession.invalidateAndCancel()
            self.session = delegateSession
            self.task = delegateTask
            delegateTask.resume()
        }
    }
}

extension VolcengineASRConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DebugLog.info("[VolcengineASR] WebSocket 已连接, protocol=\(`protocol` ?? "nil")")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isCancelled else {
                webSocketTask.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
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
        DebugLog.info("[VolcengineASR] 取消连接")
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isCancelled = true
            self.task.cancel(with: .goingAway, reason: nil)
            self.session.invalidateAndCancel()
        }
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        guard !isCancelled else { return }
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
        guard !isCancelled else { return }
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
        volcengineLogger.debug("[protocol] \(context, privacy: .public) bytes=\(data.count, privacy: .public) prefix=\(prefix, privacy: .public)")
    }

    private static func debugHeader(_ data: Data, headerSize: Int) {
        guard data.count >= 4 else { return }
        let version = data[0] >> 4
        let type = data[1] >> 4
        let flags = data[1] & 0x0f
        let serialization = data[2] >> 4
        let compression = data[2] & 0x0f
        volcengineLogger.debug("[protocol] header version=\(version, privacy: .public) headerSize=\(headerSize, privacy: .public) type=\(type, privacy: .public) flags=\(flags, privacy: .public) serialization=\(serialization, privacy: .public) compression=\(compression, privacy: .public)")
    }

    private static func debugPayload(payloadSize: Int, payloadStart: Int, dataCount: Int, flags: UInt8) {
        volcengineLogger.debug("[protocol] payload flags=\(flags, privacy: .public) start=\(payloadStart, privacy: .public) size=\(payloadSize, privacy: .public) dataCount=\(dataCount, privacy: .public)")
    }

    private static func debugInvalidFrame(_ reason: String, data: Data) {
        let prefix = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        volcengineLogger.error("[protocol] ignored invalid frame reason=\(reason, privacy: .public) bytes=\(data.count, privacy: .public) prefix=\(prefix, privacy: .public)")
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
