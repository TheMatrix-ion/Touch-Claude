import Foundation

struct PetRules: Equatable {
    let maximumHealth = 100.0
    let maximumStamina = 100.0
    let initialHealth = 100.0
    let initialHunger = 20.0
    let initialStamina = 100.0

    let feedAmount = 30.0
    let freeFeedsPerDay = 3
    let minimumHungerToFeed = 10.0

    let effectiveTokensPerHunger = 30_000.0
    let dailyTokenHungerCap = 150.0
    let answerHealthGain = 0.5
    let dailyAnswerHealthGainCap = 3.0

    let awakeHungerPerHour = 0.5
    let sleepingHungerPerHour = 0.25
    let awakeStaminaLossPerHour = 2.0
    let sleepingStaminaRecoveryPerHour = 12.5

    let starvingThreshold = 100.0
    let starvingHealthLossPerHour = 2.0
    let exhaustedHealthLossPerHour = 0.5
    let maximumAwakeHours = 20.0
    let lackOfSleepHealthLossPerHour = 0.5
    let inactivityGraceHours = 36.0
    let inactivityHealthLossPerHour = 0.1

    let maximumManualSleep: TimeInterval = 8 * 60 * 60
    /// Covers far more than the one-minute async rescan window without letting
    /// the JSON state and hook latency grow forever.
    let processedAnswerLimit = 2_048
    let periodHistoryLimit = 90

    func effectiveTokens(for usage: AnswerUsage) -> Double {
        effectiveTokens(for: TokenUsageCounters(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        ))
    }

    func effectiveTokens(for usage: TokenUsageCounters) -> Double {
        Double(max(0, usage.outputTokens))
            + 0.20 * Double(max(0, usage.inputTokens))
            + 0.25 * Double(max(0, usage.cacheCreationTokens))
            + 0.02 * Double(max(0, usage.cacheReadTokens))
    }

    func staminaCost(forEffectiveTokens effectiveTokens: Double) -> Double {
        let raw = 0.5 + 1.5 * log2(1 + max(0, effectiveTokens) / 2_000)
        let clamped = min(8, max(0.5, raw))
        return (clamped * 2).rounded() / 2
    }
}
