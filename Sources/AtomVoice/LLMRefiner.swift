import Foundation
import os.log

private let logger = Logger(subsystem: "com.blacksquarre.AtomVoice", category: "LLMRefiner")

final class LLMRefiner {
    // 动态获取系统提示词
    private var currentSystemPrompt: String {
        let customPrompt = UserDefaults.standard.string(forKey: "llmSystemPrompt") ?? ""
        if !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customPrompt
        }
        return Self.currentDefaultSystemPrompt
    }

    static var currentDefaultSystemPrompt: String {
        let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        
        let baseInstructions = "Input is raw speech transcription. Fix obvious errors ONLY. DO NOT rewrite, add, remove, or explain anything. Return ONLY the corrected text."
        
        switch lang {
        case "zh-CN", "zh-TW":
            return """
            \(baseInstructions)
            1. Fix Chinese homophones and mis-transcribed English tech terms (e.g. 配森→Python, 杰森→JSON, 诶匹爱→API, 吉特→Git, 卡夫卡→Kafka, 瑞迪斯→Redis).
            2. Add missing sentence-ending punctuation (。？！).
            """
        case "en-US":
            return """
            \(baseInstructions)
            1. Fix mis-transcribed technical terms, proper nouns, and common English homophones.
            2. Add missing sentence-ending punctuation (.?!).
            """
        case "ja-JP":
            return """
            \(baseInstructions)
            1. Fix mis-transcribed technical terms and common Japanese homophones.
            2. Add missing sentence-ending punctuation (。？！).
            """
        case "ko-KR":
            return """
            \(baseInstructions)
            1. Fix mis-transcribed technical terms and common Korean homophones.
            2. Add missing sentence-ending punctuation (.?!).
            """
        default:
            return """
            \(baseInstructions)
            1. Fix mis-transcribed technical terms.
            2. Add missing sentence-ending punctuation.
            """
        }
    }
    /// completion: (refinedText, errorMessage) — 成功时 errorMessage 为 nil，失败时 refinedText 为 nil
    func refine(text: String, completion: @escaping (String?, String?) -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let apiKey = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"

        guard !apiKey.isEmpty else {
            completion(nil, loc("error.noApiKey"))
            return
        }

        let urlString = Self.buildCompletionsURL(base: baseURL)
        logger.debug("[refine] baseURL=\(baseURL, privacy: .public) → \(urlString, privacy: .public)")
        guard let url = URL(string: urlString) else {
            completion(nil, loc("error.invalidUrl"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": currentSystemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.1,
            "max_tokens": 1024,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))

            if let error = error {
                let nsErr = error as NSError
                let msg: String
                if nsErr.code == NSURLErrorTimedOut {
                    msg = loc("error.timeout", Double(elapsed) ?? 0)
                } else if nsErr.code == NSURLErrorNotConnectedToInternet || nsErr.code == NSURLErrorNetworkConnectionLost {
                    msg = loc("error.noNetwork")
                } else {
                    msg = error.localizedDescription
                }
                print("[LLMRefiner] 请求失败(\(elapsed)s): \(error.localizedDescription)")
                completion(nil, msg)
                return
            }

            guard let data = data else {
                completion(nil, loc("error.noData"))
                return
            }

            // HTTP 状态码错误
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                // 尝试从 JSON 提取 error.message
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                    ?? String(body.prefix(80))
                let msg = "HTTP \(httpResp.statusCode): \(detail)"
                print("[LLMRefiner] 错误(\(elapsed)s): \(msg)")
                completion(nil, msg)
                return
            }

            // Debug: 输出原始响应体
            let rawBody = String(data: data, encoding: .utf8) ?? "<无法解码>"
            logger.debug("[refine] 原始响应(\(elapsed, privacy: .public)s): \(rawBody, privacy: .public)")

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    logger.info("[refine] 完成(\(elapsed, privacy: .public)s)")
                    completion(content.trimmingCharacters(in: .whitespacesAndNewlines), nil)
                } else {
                    let bodyPreview = String(rawBody.prefix(500))
                    logger.error("[refine] 响应格式异常(\(elapsed, privacy: .public)s), body: \(bodyPreview, privacy: .public)")
                    print("[LLMRefiner] 响应格式异常(\(elapsed)s), body: \(bodyPreview)")
                    completion(nil, loc("error.badFormat"))
                }
            } catch {
                logger.error("[refine] JSON 解析错误(\(elapsed, privacy: .public)s): \(error.localizedDescription, privacy: .public)")
                print("[LLMRefiner] JSON 解析错误(\(elapsed)s): \(error)")
                completion(nil, loc("error.jsonParse"))
            }
        }.resume()
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let apiKey = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"

        guard !apiKey.isEmpty else {
            completion(false, "API Key is empty")
            return
        }

        let urlString = Self.buildCompletionsURL(base: baseURL)
        logger.debug("[testConnection] baseURL=\(baseURL, privacy: .public) → \(urlString, privacy: .public)")
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 5,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, "No response")
                return
            }
            if httpResponse.statusCode == 200 {
                completion(true, "Connection successful!")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            }
        }.resume()
    }

    // MARK: - URL 拼接（自动处理用户填写的各种格式）
    /// 支持的 baseURL 格式：
    ///   - https://api.openai.com/v1
    ///   - https://api.openai.com/v1/
    ///   - https://api.openai.com/v1/chat
    ///   - https://api.openai.com/v1/chat/
    ///   - https://api.openai.com/v1/chat/completions
    static func buildCompletionsURL(base: String) -> String {
        var b = base
        // 去掉尾部斜杠
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        // 已经是完整路径
        if b.hasSuffix("/chat/completions") {
            return b
        }
        // 已经有 /chat 结尾
        if b.hasSuffix("/chat") {
            return b + "/completions"
        }
        // 标准情况：只有 /v1 等
        return b + "/chat/completions"
    }
}
