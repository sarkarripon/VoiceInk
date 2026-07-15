import Foundation

/// Fetches the live model list from a provider's models endpoint so the
/// picker isn't limited to the hardcoded fallback list in `AIProvider`.
enum ProviderModelsFetcher {

    enum FetchError: Error {
        case unsupportedProvider
        case invalidResponse
    }

    /// Providers that expose a model-list endpoint we can query.
    static let supportedProviders: Set<AIProvider> = [
        .gemini, .groq, .openAI, .cerebras, .mistral, .anthropic,
    ]

    static func fetchModels(for provider: AIProvider, apiKey: String) async throws -> [String] {
        switch provider {
        case .gemini:
            return try await fetchGeminiModels(apiKey: apiKey)
        case .anthropic:
            return try await fetchAnthropicModels(apiKey: apiKey)
        case .groq:
            let ids = try await fetchOpenAICompatibleModels(
                url: "https://api.groq.com/openai/v1/models", apiKey: apiKey)
            let excluded = ["whisper", "tts", "guard"]
            return
                ids
                .filter { id in !excluded.contains { id.lowercased().contains($0) } }
                .sorted()
        case .openAI:
            let ids = try await fetchOpenAICompatibleModels(
                url: "https://api.openai.com/v1/models", apiKey: apiKey)
            return filterOpenAIChatModels(ids)
        case .cerebras:
            let ids = try await fetchOpenAICompatibleModels(
                url: "https://api.cerebras.ai/v1/models", apiKey: apiKey)
            return ids.sorted()
        case .mistral:
            let ids = try await fetchOpenAICompatibleModels(
                url: "https://api.mistral.ai/v1/models", apiKey: apiKey)
            return
                ids
                .filter { !$0.lowercased().contains("embed") }
                .sorted()
        default:
            throw FetchError.unsupportedProvider
        }
    }

    // MARK: - Gemini

    private static func fetchGeminiModels(apiKey: String) async throws -> [String] {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]

        let data = try await performGET(url: components.url!)

        struct GeminiModel: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
        struct Response: Decodable {
            let models: [GeminiModel]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let models = (response.models ?? [])
            .filter { model in
                model.name.contains("gemini")
                    && (model.supportedGenerationMethods ?? []).contains("generateContent")
            }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }

        return models.sorted(by: >)
    }

    // MARK: - Anthropic

    private static func fetchAnthropicModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let data = try await performRequest(request)
        return try decodeModelIDs(from: data)
    }

    // MARK: - OpenAI-compatible

    private static func fetchOpenAICompatibleModels(url: String, apiKey: String) async throws
        -> [String]
    {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data = try await performRequest(request)
        return try decodeModelIDs(from: data)
    }

    private static func filterOpenAIChatModels(_ ids: [String]) -> [String] {
        let excluded = [
            "instruct", "audio", "realtime", "search", "transcribe", "tts", "image",
            "embedding", "moderation", "dall-e", "whisper", "davinci", "babbage", "codex",
        ]
        return
            ids
            .filter { id in
                let lower = id.lowercased()
                let isChatFamily =
                    lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt")
                    || lower.range(of: "^o[0-9]", options: .regularExpression) != nil
                return isChatFamily && !excluded.contains { lower.contains($0) }
            }
            .sorted(by: >)
    }

    // MARK: - Shared

    private static func decodeModelIDs(from data: Data) throws -> [String] {
        struct Model: Decodable {
            let id: String
        }
        struct Response: Decodable {
            let data: [Model]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
            let models = response.data
        else {
            throw FetchError.invalidResponse
        }
        return models.map { $0.id }
    }

    private static func performGET(url: URL) async throws -> Data {
        try await performRequest(URLRequest(url: url, timeoutInterval: 15))
    }

    private static func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else {
            throw FetchError.invalidResponse
        }
        return data
    }
}
