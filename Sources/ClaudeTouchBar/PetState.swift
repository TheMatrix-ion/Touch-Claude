import Foundation

struct PetDailyState: Codable, Equatable {
    var periodStartedAt: Date
    var nextResetAt: Date
    var freeFeedsUsed: Int
    var tokenHungerAdded: Double
    var workHealthGained: Double
    var effectiveTokens: Double
    var workEvents: Int
}

struct PetPeriodUsage: Codable, Equatable {
    var tokenHungerAdded: Double
    var effectiveTokens: Double
}

struct AnswerAccounting: Codable, Equatable {
    let generation: Int
    let periodStartedAt: Date
}

struct PetState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var generation: Int
    var bornAt: Date
    var lastUpdatedAt: Date
    var diedAt: Date?

    var health: Double
    /// Hunger is intentionally not capped at 100. Values at or above 100 mean
    /// starving, and meals must repay the full accumulated food debt.
    var hunger: Double
    var stamina: Double

    /// A non-nil value means the pet was put to bed manually. Manual sleep ends
    /// after at most eight hours; macOS offline time is supplied to PetEngine as
    /// a separate passage and is not represented here.
    var sleepUntil: Date?
    var awakeSince: Date
    var lastExerciseAt: Date

    var daily: PetDailyState
    var processedAnswerIDs: [String]
    var answerUsageSnapshots: [String: TokenUsageCounters]
    /// Optional fields keep state files written by the first local beta
    /// decodable. PetEngine initializes them before use.
    var answerAccounting: [String: AnswerAccounting]?
    var periodUsageHistory: [String: PetPeriodUsage]?
    var longestLifetime: TimeInterval

    var isDead: Bool { diedAt != nil }

    func age(at now: Date) -> TimeInterval {
        max(0, (diedAt ?? now).timeIntervalSince(bornAt))
    }
}

struct AnswerUsage: Equatable {
    let id: String
    let completedAt: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
}

struct TokenUsageCounters: Codable, Equatable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0

    static let zero = TokenUsageCounters()

    mutating func mergeMaximum(_ other: TokenUsageCounters) {
        inputTokens = max(inputTokens, other.inputTokens)
        outputTokens = max(outputTokens, other.outputTokens)
        cacheCreationTokens = max(cacheCreationTokens, other.cacheCreationTokens)
        cacheReadTokens = max(cacheReadTokens, other.cacheReadTokens)
    }

    mutating func add(_ other: TokenUsageCounters) {
        inputTokens += max(0, other.inputTokens)
        outputTokens += max(0, other.outputTokens)
        cacheCreationTokens += max(0, other.cacheCreationTokens)
        cacheReadTokens += max(0, other.cacheReadTokens)
    }

    func asAnswerUsage(id: String, completedAt: Date) -> AnswerUsage {
        AnswerUsage(
            id: id,
            completedAt: completedAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    func delta(since previous: TokenUsageCounters) -> TokenUsageCounters {
        TokenUsageCounters(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            cacheCreationTokens: max(0, cacheCreationTokens - previous.cacheCreationTokens),
            cacheReadTokens: max(0, cacheReadTokens - previous.cacheReadTokens)
        )
    }
}

enum TimePassage {
    case online
    case offline
}
