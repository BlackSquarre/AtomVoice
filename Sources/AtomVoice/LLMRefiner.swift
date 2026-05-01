import Foundation
import os.log

private let logger = Logger(subsystem: "com.blacksquarre.AtomVoice", category: "LLMRefiner")

// MARK: - 流式 SSE 接收委托

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var accumulated = ""
    private var httpError: Int?
    private var errorBuffer = Data()
    private let isAnthropic: Bool
    private let onProgress: ((String) -> Void)?
    private let onComplete: (String?, String?) -> Void

    init(isAnthropic: Bool,
         onProgress: ((String) -> Void)?,
         onComplete: @escaping (String?, String?) -> Void) {
        self.isAnthropic = isAnthropic
        self.onProgress  = onProgress
        self.onComplete  = onComplete
    }

    // 收到响应头时检查 HTTP 状态码
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            httpError = http.statusCode
        }
        completionHandler(.allow)
    }

    // 收到数据块
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if httpError != nil {
            errorBuffer.append(data)
            return
        }
        buffer.append(data)
        processBuffer()
    }

    // 全部完成
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let nsErr = error as NSError? {
            if nsErr.code == NSURLErrorCancelled {
                // 主动取消，不触发完成回调
                return
            }
            // 其他网络错误
            DispatchQueue.main.async { self.onComplete(nil, nsErr.localizedDescription) }
            return
        }
        // HTTP 错误
        if let statusCode = httpError {
            let detail = (try? JSONSerialization.jsonObject(with: errorBuffer) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? String((String(data: errorBuffer, encoding: .utf8) ?? "").prefix(120))
            DispatchQueue.main.async { self.onComplete(nil, "HTTP \(statusCode): \(detail)") }
            return
        }
        // 成功
        let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            self.onComplete(result.isEmpty ? nil : result, result.isEmpty ? "Empty response" : nil)
        }
    }

    // MARK: - SSE 解析

    private func processBuffer() {
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        // 末尾不完整的行留在 buffer
        buffer = text.hasSuffix("\n") ? Data() : (lines.last?.data(using: .utf8) ?? Data())
        for line in lines.dropLast() {
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data: ") else { return }
        let jsonStr = String(trimmed.dropFirst(6))
        if jsonStr == "[DONE]" { return }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let token: String?
        if isAnthropic {
            // Anthropic: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
            token = (json["delta"] as? [String: Any]).flatMap { $0["text"] as? String }
        } else {
            // OpenAI: {"choices":[{"delta":{"content":"..."}}]}
            token = (json["choices"] as? [[String: Any]])
                .flatMap { $0.first }
                .flatMap { $0["delta"] as? [String: Any] }
                .flatMap { $0["content"] as? String }
        }

        if let t = token, !t.isEmpty {
            accumulated += t
            let snapshot = accumulated
            DispatchQueue.main.async { self.onProgress?(snapshot) }
        }
    }
}

// MARK: - LLMRefiner

final class LLMRefiner {

    // MARK: 系统提示词

    private var currentSystemPrompt: String {
        let custom = UserDefaults.standard.string(forKey: "llmSystemPrompt") ?? ""
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.currentDefaultSystemPrompt : custom
    }

    static var currentDefaultSystemPrompt: String {
        let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        let base = "Input is raw speech transcription. Fix obvious errors ONLY. DO NOT rewrite, add, remove, or explain anything. Return ONLY the corrected text."
        switch lang {
        case "zh-CN", "zh-TW":
            return "\(base)\n1. Fix Chinese homophones and mis-transcribed English tech terms.\n2. Add missing sentence-ending punctuation (。？！)."
        case "en-US":
            return "\(base)\n1. Fix mis-transcribed technical terms and homophones.\n2. Add missing sentence-ending punctuation (.?!)."
        case "ja-JP":
            return "\(base)\n1. Fix mis-transcribed technical terms.\n2. Add missing sentence-ending punctuation (。？！)."
        case "ko-KR":
            return "\(base)\n1. Fix mis-transcribed technical terms.\n2. Add missing sentence-ending punctuation (.?!)."
        case "es-ES":
            return "\(base)\n1. Corrige errores de transcripción, homófonos y términos técnicos.\n2. Añade puntuación final (.?!)."
        case "fr-FR":
            return "\(base)\n1. Corrige les erreurs de transcription, les homophones et les termes techniques.\n2. Ajoute la ponctuation finale (.?!)."
        case "de-DE":
            return "\(base)\n1. Korrigiere Transkriptionsfehler, Homophone und Fachbegriffe.\n2. Füge abschließende Zeichensetzung hinzu (.?!)."
        default:
            return "\(base)\n1. Fix mis-transcribed technical terms.\n2. Add missing sentence-ending punctuation."
        }
    }

    // 持有流式 session / delegate，防止被释放
    private var streamSession: URLSession?
    private var streamDelegate: StreamDelegate?

    func cancel() {
        streamSession?.invalidateAndCancel()
        streamSession = nil
        streamDelegate = nil
    }

    // MARK: - 主要接口

    /// onProgress: 流式 token 回调（主线程，可选），completion: 最终结果
    func refine(text: String,
                onProgress: ((String) -> Void)? = nil,
                completion: @escaping (String?, String?) -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let apiKey  = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let model   = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"

        guard !apiKey.isEmpty else { completion(nil, loc("error.noApiKey")); return }

        let isAnthropic = Self.isAnthropicURL(baseURL)
        let urlString   = Self.buildURL(base: baseURL)
        logger.debug("[refine] \(urlString, privacy: .public)")
        guard let url = URL(string: urlString) else { completion(nil, loc("error.invalidUrl")); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        Self.setAuth(request: &request, apiKey: apiKey, isAnthropic: isAnthropic)

        let body: [String: Any] = isAnthropic
            ? ["model": model, "system": currentSystemPrompt,
               "messages": [["role": "user", "content": text]],
               "max_tokens": 1024, "temperature": 0.1, "stream": true]
            : ["model": model,
               "messages": [["role": "system", "content": currentSystemPrompt],
                             ["role": "user",   "content": text]],
               "temperature": 0.1, "max_tokens": 1024, "stream": true]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 取消上一次未完成的请求
        streamSession?.invalidateAndCancel()

        let startTime = Date()
        let delegate = StreamDelegate(isAnthropic: isAnthropic, onProgress: onProgress) { [weak self] result, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
            logger.info("[refine] 完成 \(elapsed, privacy: .public)s")
            self?.streamSession?.finishTasksAndInvalidate()
            completion(result, error)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        streamSession  = session
        streamDelegate = delegate
        session.dataTask(with: request).resume()
    }

    // MARK: - 测试连接（非流式）

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let apiKey  = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let model   = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"

        guard !apiKey.isEmpty else { completion(false, "API Key is empty"); return }

        let isAnthropic = Self.isAnthropicURL(baseURL)
        let urlString   = Self.buildURL(base: baseURL)
        guard let url = URL(string: urlString) else { completion(false, "Invalid URL"); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        Self.setAuth(request: &request, apiKey: apiKey, isAnthropic: isAnthropic)

        let body: [String: Any] = isAnthropic
            ? ["model": model, "messages": [["role": "user", "content": "Hi"]], "max_tokens": 5]
            : ["model": model, "messages": [["role": "user", "content": "Hi"]], "max_tokens": 5]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { completion(false, error.localizedDescription); return }
            guard let http = response as? HTTPURLResponse else { completion(false, "No response"); return }
            if http.statusCode == 200 {
                completion(true, "OK")
            } else {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let detail = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                    ?? String(raw.prefix(120))
                completion(false, "HTTP \(http.statusCode): \(detail)")
            }
        }.resume()
    }

    // MARK: - 静态工具

    static func isAnthropicURL(_ base: String) -> Bool {
        base.contains("anthropic.com")
    }

    /// 根据 provider 类型构建正确的 endpoint URL
    static func buildURL(base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if isAnthropicURL(base) {
            return b.hasSuffix("/messages") ? b : b + "/messages"
        }
        return buildCompletionsURL(base: base)
    }

    /// 兼容旧调用路径（OpenAI 系列）
    static func buildCompletionsURL(base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if b.hasSuffix("/chat/completions") { return b }
        if b.hasSuffix("/chat") { return b + "/completions" }
        return b + "/chat/completions"
    }

    private static func setAuth(request: inout URLRequest, apiKey: String, isAnthropic: Bool) {
        if isAnthropic {
            request.addValue(apiKey,        forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        } else {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}
