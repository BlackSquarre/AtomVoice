import Foundation

/// 每轮只读一次设置及钥匙串，连接随后仅消费冻结快照。
final class OpenAITranscriptionProvider: CloudASRProvider {
    let engineCode = OpenAIASRSettings.engineCode
    var displayName: String { loc("menu.recognitionEngine.openai") }
    let audioConfiguration = CloudASRAudioConfiguration(
        sampleRate: 24_000,
        lowLatencyChunkDuration: 0.1,
        standardChunkDuration: 0.1,
        minimumUsefulDuration: 0,
        connectionTimeout: 5
    )
    let finalResultTimeout = 10.0
    let requiresFinalConfirmation = true

    private let snapshot: () throws -> OpenAIASRRuntimeSettings
    private let session: URLSession

    init(snapshot: @escaping () throws -> OpenAIASRRuntimeSettings = { try AppSettings.openaiASR.snapshot() },
         session: URLSession? = nil) {
        self.snapshot = snapshot
        self.session = session ?? URLSession(configuration: .default)
    }

    func prepareConnection() -> Result<any CloudASRConnection, CloudASRFailure> {
        do {
            let settings = try snapshot()
            let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                return .failure(.init(kind: .configuration, message: loc("openai.error.missingApiKey")))
            }
            guard let url = URL(string: OpenAIASRSettings.endpoint) else {
                return .failure(.init(kind: .configuration, message: loc("openai.error.configuration")))
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = audioConfiguration.connectionTimeout
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return .success(OpenAITranscriptionConnection(session: session, request: request,
                                                         configuration: settings.configuration))
        } catch let error as OpenAIASRSettingsError {
            return .failure(.init(kind: .configuration, message: error.message))
        } catch {
            return .failure(.init(kind: .configuration, message: loc("openai.error.configuration")))
        }
    }

    // 旧入口保留兼容；生产 recognizer 走 prepareConnection，避免双读密钥。
    func validateCredentials() -> String? {
        do { _ = try snapshot(); return nil }
        catch let error as OpenAIASRSettingsError { return error.message }
        catch { return loc("openai.error.configuration") }
    }

    func createConnection() -> (any CloudASRConnection)? {
        guard case .success(let connection) = prepareConnection() else { return nil }
        return connection
    }
}

/// 账户列表只说明可见性；可选项仍由本客户端已适配的实时转写能力限定。
struct OpenAIASRModelCatalog {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func fetch(apiKey: String) async throws -> [OpenAIASRModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CloudASRFailure(kind: .configuration, message: loc("openai.error.missingApiKey"))
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAITranscriptionCodec.failure(nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudASRFailure(kind: .protocolMessage, message: loc("openai.error.protocol"))
        }
        guard http.statusCode == 200 else {
            let error = (try? OpenAITranscriptionCodec.decode(data))?["error"] as? [String: Any]
            throw OpenAITranscriptionCodec.failure(error ?? [:], statusCode: http.statusCode)
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> [OpenAIASRModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let shutdown_date: String?
            }
            let data: [Entry]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CloudASRFailure(kind: .protocolMessage, message: loc("openai.error.protocol"))
        }
        let dateFormat = ISO8601DateFormatter()
        dateFormat.formatOptions = [.withFullDate]
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
        let available = Set(response.data.compactMap { entry -> String? in
            guard OpenAIASRModel(rawValue: entry.id) != nil else { return nil }
            if let shutdown = entry.shutdown_date {
                guard let date = dateFormat.date(from: shutdown), date > now else { return nil }
            }
            return entry.id
        })
        return OpenAIASRModel.allCases.filter { available.contains($0.rawValue) }
    }
}
