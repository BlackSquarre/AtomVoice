import Foundation

// MARK: - 数据模型

struct LLMProvider: Codable {
    var name: String
    var baseURL: String
    var defaultModel: String
}

final class ProviderStore {
    static let key = AppSettings.Keys.llmProviders

    static var defaults: [LLMProvider] {
        [
            LLMProvider(name: loc("provider.preset.openai"),    baseURL: "https://api.openai.com/v1",                         defaultModel: AppSettings.defaultLLMModel),
            LLMProvider(name: loc("provider.preset.anthropic"), baseURL: "https://api.anthropic.com/v1",                      defaultModel: "claude-sonnet-4-6"),
            LLMProvider(name: loc("provider.preset.deepseek"),  baseURL: "https://api.deepseek.com/v1",                       defaultModel: "deepseek-v4-flash"),
            LLMProvider(name: loc("provider.preset.moonshot"),  baseURL: "https://api.moonshot.cn/v1",                        defaultModel: "kimi-latest"),
            LLMProvider(name: loc("provider.preset.alibaba"),   baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-turbo-latest"),
            LLMProvider(name: loc("provider.preset.zhipu"),     baseURL: "https://open.bigmodel.cn/api/paas/v4",              defaultModel: "glm-4-flash"),
            LLMProvider(name: loc("provider.preset.lingyi"),    baseURL: "https://api.lingyiwanwu.com/v1",                    defaultModel: "yi-lightning"),
            LLMProvider(name: loc("provider.preset.groq"),      baseURL: "https://api.groq.com/openai/v1",                    defaultModel: "llama-3.3-70b-versatile"),
            LLMProvider(name: loc("provider.preset.ollama"),    baseURL: "http://localhost:11434/v1",                         defaultModel: "qwen2.5:1.5b"),
            LLMProvider(name: loc("provider.preset.custom"),    baseURL: "",                                                  defaultModel: ""),
        ]
    }

    static func load(backend: SettingsBackend = AppSettings.backend) -> [LLMProvider] {
        guard let data = backend.data(forKey: key),
              let list = try? JSONDecoder().decode([LLMProvider].self, from: data)
        else { return defaults }
        return list
    }

    static func save(_ list: [LLMProvider], backend: SettingsBackend = AppSettings.backend) {
        if let data = try? JSONEncoder().encode(list) {
            backend.set(data, forKey: key)
        }
    }
}
