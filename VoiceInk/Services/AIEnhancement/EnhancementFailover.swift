import Foundation

/// Pure helpers for model failover: candidate ordering and error classification.
enum EnhancementFailover {
    /// Models to try in order. `nil` means "use the provider's default model".
    static func candidateModels(primary: String?, fallbacks: [String]) -> [String?] {
        var candidates: [String?] = [primary]
        for model in fallbacks where !model.isEmpty && model != primary {
            candidates.append(model)
        }
        return candidates
    }

    /// Whether an error should advance to the next fallback model.
    static func isTransient(_ error: Error) -> Bool {
        if let enhancementError = error as? EnhancementError {
            switch enhancementError {
            case .networkError, .serverError, .rateLimitExceeded, .timeout, .modelNotFound:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost]
                .contains(nsError.code)
    }

    /// Whether a fully failed pass over all candidates deserves another backoff cycle.
    /// Timeouts only retry when the user has opted in (existing EnhancementRetryOnTimeout setting).
    static func shouldRetryCycle(after error: Error, retryOnTimeout: Bool) -> Bool {
        guard let enhancementError = error as? EnhancementError else {
            return isTransient(error)
        }
        switch enhancementError {
        case .timeout:
            return retryOnTimeout
        case .networkError, .serverError, .rateLimitExceeded:
            return true
        default:
            return false
        }
    }
}
