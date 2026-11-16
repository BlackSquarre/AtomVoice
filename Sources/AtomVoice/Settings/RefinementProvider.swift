import Foundation

/// 识别供应商对应的润色能力；只判断非敏感配置，不读取或迁移凭据。
enum RefinementProvider {
    case openAI

    static func forRecognitionEngine(_ code: String) -> Self? {
        code == ASREngineRegistry.openAICode ? .openAI : nil
    }

    var baseURL: String { AppSettings.defaultLLMBaseURL }
    var model: String { AppSettings.defaultLLMModel }
    var nameKey: String { "provider.preset.openai" }

    func matches(baseURL: String) -> Bool {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.openai.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        // 兼容既有请求编码器接受的官方基础地址与完整 chat/completions 地址。
        return ["/v1", "/v1/chat", "/v1/chat/completions"].contains(path)
    }
}
