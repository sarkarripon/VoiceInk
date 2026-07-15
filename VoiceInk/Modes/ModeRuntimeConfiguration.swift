import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig?
    let model: any TranscriptionModel
    let language: String
    let isRealtimeEnabled: Bool

    var metadata: (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: language,
            prompt: model.provider == .whisper ? UserDefaults.standard.string(forKey: "TranscriptionPrompt") : nil
        )
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let modelFallbacks: [String]
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    init(
        mode: ModeConfig?, isEnabled: Bool, prompt: CustomPrompt?, provider: AIProvider?,
        modelName: String?, modelFallbacks: [String] = [], useClipboardContext: Bool,
        useSelectedTextContext: Bool, useScreenCaptureContext: Bool
    ) {
        self.mode = mode
        self.isEnabled = isEnabled
        self.prompt = prompt
        self.provider = provider
        self.modelName = modelName
        self.modelFallbacks = modelFallbacks
        self.useClipboardContext = useClipboardContext
        self.useSelectedTextContext = useSelectedTextContext
        self.useScreenCaptureContext = useScreenCaptureContext
    }

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            modelFallbacks: modelFallbacks,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }

    func replacingModel(_ modelName: String) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: isEnabled,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            modelFallbacks: modelFallbacks,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let autoSendKey: AutoSendKey
    let customCommand: ModeCustomCommand?
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let model = resolvedModel(
            named: mode?.selectedTranscriptionModelName,
            transcriptionModelManager: transcriptionModelManager
        )

        guard let model else { return nil }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode?.selectedLanguage,
            for: model,
            realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
        )

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(
                for: model, modeValue: mode?.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled
                ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let prompt = resolvedPrompt(
            promptId: mode?.selectedPrompt,
            enhancementService: enhancementService
        )
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            aiService: aiService
        )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: mode?.selectedAIModel,
            aiService: aiService
        )
        let modelFallbacks = resolvedEnhancementModelFallbacks(
            provider: provider,
            configuredFallbacks: mode?.aiModelFallbacks,
            primaryModelName: modelName,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            modelFallbacks: modelFallbacks,
            useClipboardContext: mode?.useClipboardContext ?? false,
            useSelectedTextContext: mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            autoSendKey: mode?.autoSendKey ?? .none,
            customCommand: mode?.customCommand
        )
    }

    private static func resolvedModel(
        named modelName: String?,
        transcriptionModelManager: TranscriptionModelManager
    ) -> (any TranscriptionModel)? {
        if let modelName,
            let model = transcriptionModelManager.usableModels.first(where: { $0.name == modelName })
        {
            return model
        }

        return transcriptionModelManager.usableModels.first
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
            let uuid = UUID(uuidString: promptId)
        else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private static func resolvedProvider(
        providerName: String?,
        aiService: AIService
    ) -> AIProvider? {
        if let providerName,
            let provider = AIProvider(rawValue: providerName),
            aiService.connectedProviders.contains(provider)
        {
            return provider
        }

        return aiService.connectedProviders.first
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
            !configuredModelName.isEmpty,
            (models.isEmpty || models.contains(configuredModelName))
        {
            return configuredModelName
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }

    private static func resolvedEnhancementModelFallbacks(
        provider: AIProvider?,
        configuredFallbacks: [String]?,
        primaryModelName: String?,
        aiService: AIService
    ) -> [String] {
        guard let provider, provider != .localCLI,
            let configuredFallbacks, !configuredFallbacks.isEmpty
        else { return [] }

        let models = aiService.availableModels(for: provider)
        var seen = Set<String>()
        return configuredFallbacks.filter { model in
            !model.isEmpty
                && model != primaryModelName
                && (models.isEmpty || models.contains(model))
                && seen.insert(model).inserted
        }
    }
}
