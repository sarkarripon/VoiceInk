import Foundation
import LLMkit
import SwiftData

struct GroqProvider: CloudProvider {
    let modelProvider: ModelProvider = .groq
    let providerKey: String = "Groq"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    /// Model IDs come from the Groq API (cached by GroqModelCatalog);
    /// the fallback list is only used before the first successful fetch.
    var models: [CloudModel] {
        let modelIDs = GroqModelCatalog.shared.cachedModelIDs ?? fallbackModelIDs
        return modelIDs.map { modelID in
            let isMultilingual = GroqModelCatalog.isMultilingual(modelID: modelID)
            return CloudModel(
                name: modelID,
                displayName: GroqModelCatalog.displayName(forModelID: modelID),
                description: "\(GroqModelCatalog.displayName(forModelID: modelID)) model with Groq's lightning-speed inference",
                provider: .groq,
                speed: 0.65,
                accuracy: 0.95,
                isMultilingual: isMultilingual,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: isMultilingual, provider: .groq)
            )
        }
    }

    private var fallbackModelIDs: [String] {
        ["whisper-large-v3-turbo", "whisper-large-v3"]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?, customVocabulary: [String]
    ) async throws -> String {
        return try await OpenAITranscriptionClient.transcribe(
            baseURL: URL(string: "https://api.groq.com/openai")!,
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await OpenAITranscriptionClient.verifyAPIKey(
            baseURL: URL(string: "https://api.groq.com/openai")!,
            apiKey: key
        )
    }
}
