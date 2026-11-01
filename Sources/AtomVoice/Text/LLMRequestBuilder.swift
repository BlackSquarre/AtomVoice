import Foundation

struct LLMRefinementConfiguration {
    let connection: LLMConnectionSettings
    let systemPrompt: String

    static var current: Self {
        let language = AppSettings.selectedLanguage
        let custom = AppSettings.llmSystemPrompt
        return .init(connection: AppSettings.llmConnection,
            systemPrompt: custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? LLMRefiner.defaultSystemPrompt(language: language) : custom)
    }
}

/// 请求编码不拥有网络任务；连接和提示词均来自本轮快照。
enum LLMRequestBuilder {
    enum RequestError: LocalizedError {
        case missingKey, invalidURL
        var errorDescription: String? {
            switch self {
            case .missingKey: return loc("error.noApiKey")
            case .invalidURL: return loc("error.invalidUrl")
            }
        }
    }

    static func refinement(text: String, configuration: LLMRefinementConfiguration) throws -> URLRequest {
        let connection = configuration.connection
        guard !connection.apiKey.isEmpty else { throw RequestError.missingKey }
        guard let url = URL(string: buildURL(base: connection.baseURL)) else { throw RequestError.invalidURL }
        let anthropic = isAnthropicURL(connection.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        setAuth(request: &request, apiKey: connection.apiKey, isAnthropic: anthropic)
        let body: [String: Any] = anthropic
            ? ["model": connection.model, "system": configuration.systemPrompt,
               "messages": [["role": "user", "content": text]],
               "max_tokens": 1024, "temperature": 0.1, "stream": true]
            : ["model": connection.model,
               "messages": [["role": "system", "content": configuration.systemPrompt],
                            ["role": "user", "content": text]],
               "temperature": 0.1, "max_tokens": 1024, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func isAnthropicURL(_ base: String) -> Bool {
        base.contains("anthropic.com")
    }

    /// 根据 provider 类型构建正确的 endpoint URL（Build the correct endpoint URL based on provider type）
    static func buildURL(base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if isAnthropicURL(base) {
            return b.hasSuffix("/messages") ? b : b + "/messages"
        }
        return buildCompletionsURL(base: base)
    }

    /// 兼容旧调用路径（OpenAI 系列）（Backward-compatible with legacy call paths (OpenAI series)）
    static func buildCompletionsURL(base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if b.hasSuffix("/chat/completions") { return b }
        if b.hasSuffix("/chat") { return b + "/completions" }
        return b + "/chat/completions"
    }

    static func setAuth(request: inout URLRequest, apiKey: String, isAnthropic: Bool) {
        if isAnthropic {
            request.addValue(apiKey,        forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        } else {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}
