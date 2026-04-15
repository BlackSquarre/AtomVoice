import Foundation

final class LLMRefiner {
    private let systemPrompt = """
    You are a speech recognition post-processor. Your ONLY job is to fix obvious speech recognition errors and punctuation. Be extremely conservative.

    Rules:
    1. Fix clear homophone errors in Chinese (e.g., wrong tones producing wrong characters).
    2. Fix English technical terms that were incorrectly transcribed as Chinese phonetic equivalents:
       - 配森 → Python, 杰森 → JSON, 瑞安 → Ryan, 诶匹爱 → API, 吉特 → Git, 吉特哈布 → GitHub
       - 卡夫卡 → Kafka, 瑞迪斯 → Redis, 多克 → Docker, 库伯奈提斯 → Kubernetes
       - Similar patterns for other technical terms
    3. Fix punctuation: ensure every sentence ends with appropriate punctuation. Use full-width punctuation for Chinese/Japanese (。？！), half-width for English (.?!). Detect sentence type (statement→。/. question→？/? exclamation→！/!) based on context. Fix incorrectly placed punctuation.
    4. DO NOT rewrite, rephrase, add, remove, or "improve" any content.
    5. DO NOT change sentence structure or word order.
    6. DO NOT add explanations or commentary.
    7. If the input looks correct, return it EXACTLY as-is.
    8. Return ONLY the corrected text, nothing else.
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
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.1,
            "max_tokens": 2048,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("[LLMRefiner] Request failed: \(error?.localizedDescription ?? "unknown")")
                completion(nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    print("[LLMRefiner] Unexpected response format")
                    completion(nil)
                }
            } catch {
                print("[LLMRefiner] JSON parse error: \(error)")
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
