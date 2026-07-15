import Foundation
import SwiftUI
import os

@MainActor
class TranscriptionModelManager: ObservableObject {
    @Published var currentTranscriptionModel: (any TranscriptionModel)?
    @Published var allAvailableModels: [any TranscriptionModel] = TranscriptionModelRegistry.models

    /// Apple Speech counts as "connected" only after the user has downloaded
    /// at least one language asset (reserved locale) for it.
    @Published private(set) var isNativeAppleSpeechConfigured = false

    private weak var whisperModelManager: WhisperModelManager?
    private weak var fluidAudioModelManager: FluidAudioModelManager?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionModelManager")

    init(whisperModelManager: WhisperModelManager, fluidAudioModelManager: FluidAudioModelManager) {
        self.whisperModelManager = whisperModelManager
        self.fluidAudioModelManager = fluidAudioModelManager

        // Wire up deletion callbacks so each manager notifies this manager.
        whisperModelManager.onModelDeleted = { [weak self] modelName in
            self?.handleModelDeleted(modelName)
        }
        fluidAudioModelManager.onModelDeleted = { [weak self] modelName in
            self?.handleModelDeleted(modelName)
        }

        // Wire up "models changed" callbacks so this manager rebuilds allAvailableModels.
        whisperModelManager.onModelsChanged = { [weak self] in
            self?.refreshAllAvailableModels()
        }
        fluidAudioModelManager.onModelsChanged = { [weak self] in
            self?.refreshAllAvailableModels()
        }

        // Cloud provider model lists are fetched from the provider APIs.
        NotificationCenter.default.addObserver(
            forName: .cloudModelsDidRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllAvailableModels()
            }
        }

        // Re-fetch cloud model lists when a provider API key is added or changed.
        NotificationCenter.default.addObserver(
            forName: .aiProviderKeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await GroqModelCatalog.shared.refresh()
            }
        }

        // Apple Speech asset state changes outside this manager (downloads in
        // settings/language views), so re-check whenever app settings change.
        NotificationCenter.default.addObserver(
            forName: .AppSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNativeAppleSpeechConfiguration()
            }
        }

        Task {
            await GroqModelCatalog.shared.refresh()
            await refreshNativeAppleSpeechConfiguration()
        }
    }

    func refreshNativeAppleSpeechConfiguration() async {
        let reservedLocales = await NativeAppleSpeechAssetManager.reservedLocaleIdentifiers()
        let isConfigured = !reservedLocales.isEmpty
        if isNativeAppleSpeechConfigured != isConfigured {
            isNativeAppleSpeechConfigured = isConfigured
        }
    }

    // MARK: - Computed: usable models

    var usableModels: [any TranscriptionModel] {
        allAvailableModels.filter { model in
            switch model.provider {
            case .whisper:
                return whisperModelManager?.availableModels.contains { $0.name == model.name } ?? false
            case .fluidAudio:
                return fluidAudioModelManager?.isFluidAudioModelDownloaded(named: model.name) ?? false
            case .nativeApple:
                if #available(macOS 26, *) { return isNativeAppleSpeechConfigured } else { return false }
            case .custom:
                return true
            default:
                if let cloudProvider = CloudProviderRegistry.provider(for: model.provider) {
                    return APIKeyManager.shared.hasAPIKey(forProvider: cloudProvider.providerKey)
                }
                return false
            }
        }
    }

    func isAvailableOnCurrentOS(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .nativeApple:
            if #available(macOS 26, *) { return true } else { return false }
        default:
            return true
        }
    }

    // MARK: - Model loading from UserDefaults

    func loadCurrentTranscriptionModel() {
        if let savedModelName = UserDefaults.standard.string(forKey: "CurrentTranscriptionModel"),
            let savedModel = allAvailableModels.first(where: { $0.name == savedModelName })
        {
            guard isAvailableOnCurrentOS(savedModel) else {
                UserDefaults.standard.removeObject(forKey: "CurrentTranscriptionModel")
                currentTranscriptionModel = nil
                return
            }

            currentTranscriptionModel = savedModel
            ensureSelectedLanguageIsSupported(by: savedModel)
        }
    }

    // MARK: - Set default model

    func setDefaultTranscriptionModel(_ model: any TranscriptionModel) {
        guard isAvailableOnCurrentOS(model) else {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "%@ requires macOS 26 or later"), model.displayName),
                type: .error
            )
            return
        }

        self.currentTranscriptionModel = model
        UserDefaults.standard.set(model.name, forKey: "CurrentTranscriptionModel")
        ensureSelectedLanguageIsSupported(by: model)

        if model.provider != .whisper {
            whisperModelManager?.loadedWhisperModel = nil
            whisperModelManager?.isModelLoaded = true
        }

        NotificationCenter.default.post(name: .didChangeModel, object: nil, userInfo: ["modelName": model.name])
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func ensureSelectedLanguageIsSupported(by model: any TranscriptionModel) {
        let currentLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage")
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(currentLanguage, for: model)

        if currentLanguage != compatibleLanguage {
            UserDefaults.standard.set(compatibleLanguage, forKey: "SelectedLanguage")
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    // MARK: - Refresh all available models

    func refreshAllAvailableModels() {
        let currentModelName = currentTranscriptionModel?.name
        var models = TranscriptionModelRegistry.models

        for whisperModel in whisperModelManager?.availableModels ?? [] {
            if !models.contains(where: { $0.name == whisperModel.name }) {
                let importedModel = ImportedWhisperModel(fileBaseName: whisperModel.name)
                models.append(importedModel)
            }
        }

        allAvailableModels = models

        if let currentName = currentModelName,
            let updatedModel = allAvailableModels.first(where: { $0.name == currentName })
        {
            setDefaultTranscriptionModel(updatedModel)
        }
    }

    // MARK: - Clear current model

    func clearCurrentTranscriptionModel() {
        currentTranscriptionModel = nil
        UserDefaults.standard.removeObject(forKey: "CurrentTranscriptionModel")
    }

    // MARK: - Handle model deletion callback

    /// Called by WhisperModelManager.onModelDeleted or FluidAudioModelManager.onModelDeleted.
    func handleModelDeleted(_ modelName: String) {
        if currentTranscriptionModel?.name == modelName {
            currentTranscriptionModel = nil
            UserDefaults.standard.removeObject(forKey: "CurrentTranscriptionModel")
            whisperModelManager?.loadedWhisperModel = nil
            whisperModelManager?.isModelLoaded = false
            UserDefaults.standard.removeObject(forKey: "CurrentModel")
        }
        refreshAllAvailableModels()
    }
}
