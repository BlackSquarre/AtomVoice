import Foundation

final class LLMRefiner {
    private let systemPrompt = """
    Fix obvious speech recognition errors only. Rules:
    1. Fix Chinese homophones and mis-transcribed English tech terms (e.g. 配森→Python, 杰森→JSON, 诶匹爱→API, 吉特→Git, 卡夫卡→Kafka, 瑞迪斯→Redis).
    2. Add missing sentence-ending punctuation (Chinese: 。？！, English: .?!).
    3. DO NOT rewrite, add, remove, or explain anything. Return ONLY the corrected text.
    """

    func refine(text: String, completion: @escaping (String?) -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1"
        let apiKey = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini"

        guard !apiKey.isEmpty else {
            completion(nil)
            return
        }

        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)chat/completions" : "\(baseURL)/chat/completions"
        guard let url = URL(string: urlString) else {
            completion(nil)
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
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.1,
            "max_tokens": 1024,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
            guard let data = data, error == nil else {
                print("[LLMRefiner] 请求失败(\(elapsed)s): \(error?.localizedDescription ?? "unknown")")
                completion(nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    print("[LLMRefiner] 完成(\(elapsed)s)")
                    completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    print("[LLMRefiner] 响应格式异常(\(elapsed)s)")
                    completion(nil)
                }
            } catch {
                print("[LLMRefiner] JSON 解析错误(\(elapsed)s): \(error)")
                completion(nil)
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

        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)chat/completions" : "\(baseURL)/chat/completions"
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
}
