import Foundation
import os

/// Fetches the list of Groq speech-to-text models from the Groq API and caches it,
/// so the available models are not hardcoded in the app.
final class GroqModelCatalog: @unchecked Sendable {
    static let shared = GroqModelCatalog()

    private static let cacheKey = "GroqTranscriptionModelIDs"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "GroqModelCatalog")
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.groqModelCatalog")

    private init() {}

    /// Model IDs from the last successful API fetch, or nil if never fetched.
    var cachedModelIDs: [String]? {
        queue.sync {
            UserDefaults.standard.stringArray(forKey: Self.cacheKey)
        }
    }

    /// Fetches speech-to-text model IDs from the Groq API and caches them.
    /// Posts `.cloudModelsDidRefresh` when the cached list changes.
    func refresh() async {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Groq") else { return }
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                logger.error("Groq models request failed with non-success status")
                return
            }

            let modelList = try JSONDecoder().decode(ModelListResponse.self, from: data)
            let transcriptionModelIDs =
                modelList.data
                .filter { $0.isActive && Self.isTranscriptionModel(id: $0.id) }
                .map { $0.id }
                .sorted()

            guard !transcriptionModelIDs.isEmpty else {
                logger.warning("Groq models response contained no transcription models; keeping existing cache")
                return
            }

            let changed = queue.sync { () -> Bool in
                let existing = UserDefaults.standard.stringArray(forKey: Self.cacheKey)
                guard existing != transcriptionModelIDs else { return false }
                UserDefaults.standard.set(transcriptionModelIDs, forKey: Self.cacheKey)
                return true
            }

            if changed {
                logger.info("Groq transcription models updated: \(transcriptionModelIDs.joined(separator: ", "), privacy: .public)")
                await MainActor.run {
                    NotificationCenter.default.post(name: .cloudModelsDidRefresh, object: nil)
                }
            }
        } catch {
            logger.error("Failed to fetch Groq models: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Groq serves LLMs and TTS models from the same endpoint; only whisper-family IDs transcribe audio.
    static func isTranscriptionModel(id: String) -> Bool {
        id.lowercased().contains("whisper")
    }

    static func displayName(forModelID id: String) -> String {
        if let known = knownDisplayNames[id] { return known }

        let words = id.split(separator: "-").map { word -> String in
            let lower = word.lowercased()
            if lower == "en" { return "(English)" }
            if lower.first == "v", lower.dropFirst().allSatisfy(\.isNumber) { return lower }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// Groq marks English-only variants with an "-en" / ".en" suffix.
    static func isMultilingual(modelID id: String) -> Bool {
        !(id.hasSuffix("-en") || id.hasSuffix(".en"))
    }

    private static let knownDisplayNames: [String: String] = [
        "whisper-large-v3": "Whisper Large v3",
        "whisper-large-v3-turbo": "Whisper Large v3 Turbo",
        "distil-whisper-large-v3-en": "Distil Whisper Large v3 (English)",
    ]

    private struct ModelListResponse: Decodable {
        let data: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
        let id: String
        let active: Bool?

        var isActive: Bool { active ?? true }
    }
}
