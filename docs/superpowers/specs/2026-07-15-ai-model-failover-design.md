# AI Enhancement Model Failover — Design

Date: 2026-07-15
Status: Approved

## Problem

AI enhancement uses one model per mode. When the provider rate-limits (HTTP 429) or has a
transient outage, enhancement retries the same model with backoff and then fails the
dictation. Users want ordered fallback models so enhancement transparently fails over.

## Decisions (confirmed with user)

- **Same provider only.** Fallback models come from the mode's selected AI provider.
- **Trigger on any transient failure:** 429, 5xx, timeout, network error. Non-transient
  errors (auth, bad request) fail immediately as today.
- **Ordering by selection order.** The order models are picked is the failover order,
  displayed as a numbered list. Remove/re-add to reorder.

## Data model

- `ModeConfig.aiModelFallbacks: [String]?` — ordered model IDs; optional so existing
  persisted configs (UserDefaults `modeConfigurationsV2` JSON) decode unchanged.
- `ModeConfigDraft.aiModelFallbacks: [String]` — non-optional in the editor draft;
  saved as `nil` when empty.

## UI (ModeConfigFormView, AI Enhancement section)

Directly below the AI Model picker:

- "Fallback Models" row with an Add menu listing the provider's available models,
  excluding the primary model and already-selected fallbacks.
- Selected fallbacks render as numbered rows (`1.`, `2.`, …) each with a remove button.
- Changing the AI Provider clears the fallback list.
- Selecting a primary model that is currently a fallback removes it from the fallbacks.
- Hidden for `.localCLI` (no model selection).

## Runtime

- `EnhancementRuntimeConfiguration.modelFallbacks: [String]` — resolver
  (`ModeRuntimeResolver.currentEnhancementConfiguration`) validates each fallback against
  `aiService.availableModels(for:)` (when non-empty), drops duplicates and the primary.
- `EnhancementRuntimeConfiguration.replacingModel(_:)` returns a copy with a different
  `modelName` for fallback attempts.

## Failover logic (AIEnhancementService.makeRequestWithRetry)

Candidates = `[primary] + fallbacks`. Up to `maxRetries` (3) cycles:

1. Try each candidate in order. Success returns immediately (log when a fallback won).
2. Transient error (`.rateLimitExceeded`, `.serverError`, `.networkError`, `.timeout`,
   NSURLError connection codes) advances to the next candidate immediately — no backoff
   wait mid-dictation.
3. Non-transient error throws immediately.
4. After a full failed cycle: sleep with exponential backoff and cycle again for
   rate-limit/server/network errors; timeout cycles only when the existing
   `EnhancementRetryOnTimeout` setting is on (no sleep, matching current behavior).
5. All cycles exhausted: throw the last error.

With zero fallbacks this reduces to today's behavior (3 attempts, exponential backoff,
timeout gated by `EnhancementRetryOnTimeout`).

Error classification and candidate-list building live in a small pure helper
(`EnhancementFailover`) so they are unit-testable without the service's dependencies.

## Testing

- Unit tests (Swift Testing, VoiceInkTests): candidate ordering, dedupe against primary,
  transient/non-transient classification, empty-fallback equivalence.
- Manual: set bogus primary model + valid fallback, dictate, confirm enhancement succeeds
  via fallback and log line names the model used.

## Out of scope

- Cross-provider failover.
- Health tracking / remembering which model rate-limited.
- Failover for transcription models.
