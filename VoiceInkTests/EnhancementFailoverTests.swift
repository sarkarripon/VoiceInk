import Foundation
import Testing

@testable import VoiceInk

struct EnhancementFailoverTests {

    // MARK: - candidateModels

    @Test func primaryOnlyWhenNoFallbacks() {
        let candidates = EnhancementFailover.candidateModels(primary: "a", fallbacks: [])
        #expect(candidates == ["a"])
    }

    @Test func fallbacksKeepSelectionOrder() {
        let candidates = EnhancementFailover.candidateModels(primary: "a", fallbacks: ["b", "c", "d"])
        #expect(candidates == ["a", "b", "c", "d"])
    }

    @Test func fallbackMatchingPrimaryIsDropped() {
        let candidates = EnhancementFailover.candidateModels(primary: "a", fallbacks: ["a", "b"])
        #expect(candidates == ["a", "b"])
    }

    @Test func emptyFallbackNamesAreDropped() {
        let candidates = EnhancementFailover.candidateModels(primary: "a", fallbacks: ["", "b"])
        #expect(candidates == ["a", "b"])
    }

    @Test func nilPrimaryMeansProviderDefault() {
        let candidates = EnhancementFailover.candidateModels(primary: nil, fallbacks: ["b"])
        #expect(candidates == [nil, "b"])
    }

    // MARK: - isTransient

    @Test func transientEnhancementErrorsAdvanceToNextModel() {
        #expect(EnhancementFailover.isTransient(EnhancementError.rateLimitExceeded))
        #expect(EnhancementFailover.isTransient(EnhancementError.serverError))
        #expect(EnhancementFailover.isTransient(EnhancementError.networkError))
        #expect(EnhancementFailover.isTransient(EnhancementError.timeout))
    }

    @Test func nonTransientEnhancementErrorsFailImmediately() {
        #expect(!EnhancementFailover.isTransient(EnhancementError.notConfigured))
        #expect(!EnhancementFailover.isTransient(EnhancementError.enhancementFailed))
        #expect(!EnhancementFailover.isTransient(EnhancementError.customError("HTTP 401: unauthorized")))
    }

    @Test func urlConnectionErrorsAreTransient() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(EnhancementFailover.isTransient(error))

        let other = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        #expect(!EnhancementFailover.isTransient(other))
    }

    // MARK: - shouldRetryCycle

    @Test func rateLimitRetriesAnotherCycle() {
        #expect(
            EnhancementFailover.shouldRetryCycle(
                after: EnhancementError.rateLimitExceeded, retryOnTimeout: false))
    }

    @Test func timeoutCycleGatedByRetryOnTimeout() {
        #expect(EnhancementFailover.shouldRetryCycle(after: EnhancementError.timeout, retryOnTimeout: true))
        #expect(!EnhancementFailover.shouldRetryCycle(after: EnhancementError.timeout, retryOnTimeout: false))
    }

    @Test func nonTransientNeverRetriesCycle() {
        #expect(
            !EnhancementFailover.shouldRetryCycle(
                after: EnhancementError.customError("HTTP 400: bad request"), retryOnTimeout: true))
    }

    // MARK: - ModeConfig persistence

    @Test func modeConfigRoundTripsFallbacks() throws {
        var config = ModeConfig(name: "Test", isAIEnhancementEnabled: true)
        config.aiModelFallbacks = ["b", "c"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: data)
        #expect(decoded.aiModelFallbacks == ["b", "c"])
    }

    @Test func modeConfigWithoutFallbacksDecodesAsNil() throws {
        let config = ModeConfig(name: "Test", isAIEnhancementEnabled: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: data)
        #expect(decoded.aiModelFallbacks == nil)
    }
}
