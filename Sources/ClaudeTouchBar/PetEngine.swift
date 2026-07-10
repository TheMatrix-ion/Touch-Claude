import Foundation

enum PetActionError: Error, CustomStringConvertible, Equatable {
    case dead
    case stillAlive
    case notHungry
    case noFreeFeedRemaining
    case alreadySleeping
    case alreadyAwake
    case staleAnswer

    var description: String {
        switch self {
        case .dead: return "clawd has died; run `clawd hatch` to start again"
        case .stillAlive: return "clawd is still alive"
        case .notHungry: return "clawd is not hungry enough to feed"
        case .noFreeFeedRemaining: return "today's three free feeds are used; paid food is not implemented yet"
        case .alreadySleeping: return "clawd is already sleeping"
        case .alreadyAwake: return "clawd is already awake"
        case .staleAnswer: return "answer completed before this clawd was born"
        }
    }
}

struct FeedResult: Equatable {
    let hungerBefore: Double
    let hungerAfter: Double
    let freeFeedsRemaining: Int
}

struct WorkResult: Equatable {
    let duplicate: Bool
    let effectiveTokens: Double
    let hungerAdded: Double
    let staminaSpent: Double
    let healthAdded: Double
}

struct PetEngine {
    let rules: PetRules
    let calendar: Calendar

    init(rules: PetRules = PetRules(), calendar: Calendar = .autoupdatingCurrent) {
        self.rules = rules
        self.calendar = calendar
    }

    func hatch(at now: Date, generation: Int = 1, longestLifetime: TimeInterval = 0) -> PetState {
        let dayStart = calendar.startOfDay(for: now)
        let nextReset = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return PetState(
            schemaVersion: PetState.currentSchemaVersion,
            id: UUID(),
            generation: generation,
            bornAt: now,
            lastUpdatedAt: now,
            diedAt: nil,
            health: rules.initialHealth,
            hunger: rules.initialHunger,
            stamina: rules.initialStamina,
            sleepUntil: nil,
            awakeSince: now,
            lastExerciseAt: now,
            daily: PetDailyState(
                periodStartedAt: dayStart,
                nextResetAt: nextReset,
                freeFeedsUsed: 0,
                tokenHungerAdded: 0,
                workHealthGained: 0,
                effectiveTokens: 0,
                workEvents: 0
            ),
            processedAnswerIDs: [],
            answerUsageSnapshots: [:],
            answerAccounting: [:],
            periodUsageHistory: [:],
            longestLifetime: longestLifetime
        )
    }

    func advance(_ state: inout PetState, to requestedNow: Date, passage: TimePassage) {
        guard !state.isDead else { return }
        let now = max(requestedNow, state.lastUpdatedAt)
        guard now > state.lastUpdatedAt else {
            resetDailyIfNeeded(&state, at: now)
            return
        }

        if passage == .offline {
            advanceSegment(&state, to: now, sleeping: true)
            if state.sleepUntil.map({ $0 <= now }) == true {
                state.sleepUntil = nil
            }
            state.awakeSince = now
        } else if let sleepUntil = state.sleepUntil, sleepUntil > state.lastUpdatedAt {
            let asleepEnd = min(now, sleepUntil)
            advanceSegment(&state, to: asleepEnd, sleeping: true)
            if !state.isDead, now > asleepEnd {
                state.sleepUntil = nil
                state.awakeSince = asleepEnd
                advanceSegment(&state, to: now, sleeping: false)
            } else if asleepEnd >= sleepUntil {
                state.sleepUntil = nil
                state.awakeSince = asleepEnd
            }
        } else {
            state.sleepUntil = nil
            advanceSegment(&state, to: now, sleeping: false)
        }
        resetDailyIfNeeded(&state, at: now)
    }

    func feed(_ state: inout PetState, at now: Date) throws -> FeedResult {
        advance(&state, to: now, passage: .online)
        guard !state.isDead else { throw PetActionError.dead }
        guard state.hunger >= rules.minimumHungerToFeed else { throw PetActionError.notHungry }
        guard state.daily.freeFeedsUsed < rules.freeFeedsPerDay else {
            throw PetActionError.noFreeFeedRemaining
        }

        let before = state.hunger
        state.hunger = max(0, state.hunger - rules.feedAmount)
        state.daily.freeFeedsUsed += 1
        return FeedResult(
            hungerBefore: before,
            hungerAfter: state.hunger,
            freeFeedsRemaining: rules.freeFeedsPerDay - state.daily.freeFeedsUsed
        )
    }

    func completeAnswer(_ state: inout PetState, usage: AnswerUsage, at now: Date) throws -> WorkResult {
        advance(&state, to: now, passage: .online)
        guard !state.isDead else { throw PetActionError.dead }
        guard usage.completedAt >= state.bornAt else { throw PetActionError.staleAnswer }
        let actionTime = state.lastUpdatedAt
        let isDuplicate = state.answerUsageSnapshots[usage.id] != nil
            || state.answerAccounting?[usage.id] != nil
            || state.processedAnswerIDs.contains(usage.id) // migration fallback
        var accounting = state.answerAccounting ?? [:]
        if isDuplicate, accounting[usage.id] == nil {
            // Migration path for state written before per-answer attribution.
            accounting[usage.id] = AnswerAccounting(
                generation: state.generation,
                periodStartedAt: state.daily.periodStartedAt
            )
            state.answerAccounting = accounting
        }
        if let owner = accounting[usage.id], owner.generation != state.generation {
            return WorkResult(duplicate: true, effectiveTokens: 0, hungerAdded: 0, staminaSpent: 0, healthAdded: 0)
        }
        let accountingPeriod = accounting[usage.id]?.periodStartedAt ?? state.daily.periodStartedAt
        let previousUsage = state.answerUsageSnapshots[usage.id] ?? .zero
        var currentUsage = previousUsage
        currentUsage.mergeMaximum(TokenUsageCounters(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        ))
        let deltaUsage = currentUsage.delta(since: previousUsage)
        let effectiveTokens = rules.effectiveTokens(for: deltaUsage)
        if isDuplicate, effectiveTokens == 0 {
            return WorkResult(duplicate: true, effectiveTokens: 0, hungerAdded: 0, staminaSpent: 0, healthAdded: 0)
        }

        if !isDuplicate, state.sleepUntil != nil {
            state.sleepUntil = nil
            state.awakeSince = actionTime
        }

        let hungerAdded = applyTokenUsage(
            &state,
            effectiveTokens: effectiveTokens,
            periodStartedAt: accountingPeriod
        )
        state.hunger += hungerAdded

        let staminaBefore = state.stamina
        let previousEffectiveTokens = rules.effectiveTokens(for: previousUsage)
        let currentEffectiveTokens = rules.effectiveTokens(for: currentUsage)
        let staminaCost: Double
        if isDuplicate {
            staminaCost = max(
                0,
                rules.staminaCost(forEffectiveTokens: currentEffectiveTokens)
                    - rules.staminaCost(forEffectiveTokens: previousEffectiveTokens)
            )
        } else {
            staminaCost = rules.staminaCost(forEffectiveTokens: currentEffectiveTokens)
        }
        state.stamina = max(0, staminaBefore - staminaCost)
        let staminaSpent = staminaBefore - state.stamina

        var healthAdded = 0.0
        if !isDuplicate, staminaBefore > 0 {
            let healthAllowance = max(0, rules.dailyAnswerHealthGainCap - state.daily.workHealthGained)
            let missingHealth = max(0, rules.maximumHealth - state.health)
            healthAdded = min(rules.answerHealthGain, healthAllowance, missingHealth)
            state.health += healthAdded
            state.daily.workHealthGained += healthAdded
        }
        if !isDuplicate {
            state.lastExerciseAt = actionTime
            state.daily.workEvents += 1
        }

        state.answerUsageSnapshots[usage.id] = currentUsage
        if !isDuplicate {
            state.processedAnswerIDs.append(usage.id)
            accounting[usage.id] = AnswerAccounting(
                generation: state.generation,
                periodStartedAt: state.daily.periodStartedAt
            )
            if state.processedAnswerIDs.count > rules.processedAnswerLimit {
                let removeCount = state.processedAnswerIDs.count - rules.processedAnswerLimit
                let removed = Array(state.processedAnswerIDs.prefix(removeCount))
                state.processedAnswerIDs.removeFirst(removeCount)
                for answerID in removed {
                    state.answerUsageSnapshots.removeValue(forKey: answerID)
                    accounting.removeValue(forKey: answerID)
                }
            }
        }
        state.answerAccounting = accounting

        return WorkResult(
            duplicate: isDuplicate,
            effectiveTokens: effectiveTokens,
            hungerAdded: hungerAdded,
            staminaSpent: staminaSpent,
            healthAdded: healthAdded
        )
    }

    func sleep(_ state: inout PetState, at now: Date) throws {
        advance(&state, to: now, passage: .online)
        guard !state.isDead else { throw PetActionError.dead }
        guard state.sleepUntil == nil else { throw PetActionError.alreadySleeping }
        state.sleepUntil = state.lastUpdatedAt.addingTimeInterval(rules.maximumManualSleep)
    }

    func wake(_ state: inout PetState, at now: Date) throws {
        advance(&state, to: now, passage: .online)
        guard !state.isDead else { throw PetActionError.dead }
        guard state.sleepUntil != nil else { throw PetActionError.alreadyAwake }
        state.sleepUntil = nil
        state.awakeSince = state.lastUpdatedAt
    }

    func rehatch(_ state: inout PetState, at now: Date) throws {
        guard state.isDead else { throw PetActionError.stillAlive }
        let hatchTime = max(now, state.diedAt ?? state.lastUpdatedAt)
        let longest = max(state.longestLifetime, state.age(at: hatchTime))
        let priorGeneration = state.generation
        let priorDaily = state.daily
        let priorAnswerIDs = state.processedAnswerIDs
        let priorUsage = state.answerUsageSnapshots
        var priorAccounting = state.answerAccounting ?? [:]
        for answerID in priorAnswerIDs where priorAccounting[answerID] == nil {
            priorAccounting[answerID] = AnswerAccounting(
                generation: priorGeneration,
                periodStartedAt: priorDaily.periodStartedAt
            )
        }
        var priorHistory = state.periodUsageHistory ?? [:]
        let sameDailyPeriod = hatchTime >= priorDaily.periodStartedAt && hatchTime < priorDaily.nextResetAt
        if !sameDailyPeriod {
            archive(priorDaily, into: &priorHistory)
        }

        var next = hatch(
            at: hatchTime,
            generation: priorGeneration + 1,
            longestLifetime: longest
        )
        if sameDailyPeriod { next.daily = priorDaily }
        next.processedAnswerIDs = priorAnswerIDs
        next.answerUsageSnapshots = priorUsage
        next.answerAccounting = priorAccounting
        next.periodUsageHistory = priorHistory
        state = next
    }

    private func resetDailyIfNeeded(_ state: inout PetState, at now: Date) {
        guard now >= state.daily.nextResetAt else { return }
        var history = state.periodUsageHistory ?? [:]
        archive(state.daily, into: &history)
        state.periodUsageHistory = history
        let dayStart = calendar.startOfDay(for: now)
        state.daily = PetDailyState(
            periodStartedAt: dayStart,
            nextResetAt: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            freeFeedsUsed: 0,
            tokenHungerAdded: 0,
            workHealthGained: 0,
            effectiveTokens: 0,
            workEvents: 0
        )
    }

    private func applyTokenUsage(
        _ state: inout PetState,
        effectiveTokens: Double,
        periodStartedAt: Date
    ) -> Double {
        let requestedHunger = effectiveTokens / rules.effectiveTokensPerHunger
        if periodStartedAt == state.daily.periodStartedAt {
            let allowance = max(0, rules.dailyTokenHungerCap - state.daily.tokenHungerAdded)
            let added = min(allowance, requestedHunger)
            state.daily.tokenHungerAdded += added
            state.daily.effectiveTokens += effectiveTokens
            return added
        }

        var history = state.periodUsageHistory ?? [:]
        let key = periodKey(periodStartedAt)
        var period = history[key] ?? PetPeriodUsage(tokenHungerAdded: 0, effectiveTokens: 0)
        let allowance = max(0, rules.dailyTokenHungerCap - period.tokenHungerAdded)
        let added = min(allowance, requestedHunger)
        period.tokenHungerAdded += added
        period.effectiveTokens += effectiveTokens
        history[key] = period
        state.periodUsageHistory = history
        return added
    }

    private func archive(_ daily: PetDailyState, into history: inout [String: PetPeriodUsage]) {
        let key = periodKey(daily.periodStartedAt)
        var saved = history[key] ?? PetPeriodUsage(tokenHungerAdded: 0, effectiveTokens: 0)
        saved.tokenHungerAdded = max(saved.tokenHungerAdded, daily.tokenHungerAdded)
        saved.effectiveTokens = max(saved.effectiveTokens, daily.effectiveTokens)
        history[key] = saved
        if history.count > rules.periodHistoryLimit {
            for oldKey in history.keys.sorted().prefix(history.count - rules.periodHistoryLimit) {
                history.removeValue(forKey: oldKey)
            }
        }
    }

    private func periodKey(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    private func advanceSegment(_ state: inout PetState, to end: Date, sleeping: Bool) {
        var cursor = state.lastUpdatedAt
        let epsilon = 0.000_001

        while !state.isDead, end.timeIntervalSince(cursor) > epsilon {
            var next = end

            if state.hunger < rules.starvingThreshold {
                let rate = sleeping ? rules.sleepingHungerPerHour : rules.awakeHungerPerHour
                if rate > 0 {
                    next = min(next, cursor.addingTimeInterval((rules.starvingThreshold - state.hunger) / rate * 3600))
                }
            }

            if sleeping, state.stamina < rules.maximumStamina {
                next = min(next, cursor.addingTimeInterval((rules.maximumStamina - state.stamina) / rules.sleepingStaminaRecoveryPerHour * 3600))
            } else if !sleeping, state.stamina > 0 {
                next = min(next, cursor.addingTimeInterval(state.stamina / rules.awakeStaminaLossPerHour * 3600))
            }

            if !sleeping {
                let tiredAt = state.awakeSince.addingTimeInterval(rules.maximumAwakeHours * 3600)
                if tiredAt > cursor { next = min(next, tiredAt) }
            }

            let inactiveAt = state.lastExerciseAt.addingTimeInterval(rules.inactivityGraceHours * 3600)
            if inactiveAt > cursor { next = min(next, inactiveAt) }

            if next.timeIntervalSince(cursor) <= epsilon {
                next = min(end, cursor.addingTimeInterval(0.001))
            }

            let hours = next.timeIntervalSince(cursor) / 3600
            var healthLossRate = 0.0
            if state.hunger >= rules.starvingThreshold { healthLossRate += rules.starvingHealthLossPerHour }
            if !sleeping, state.stamina <= 0 { healthLossRate += rules.exhaustedHealthLossPerHour }
            if !sleeping, cursor >= state.awakeSince.addingTimeInterval(rules.maximumAwakeHours * 3600) {
                healthLossRate += rules.lackOfSleepHealthLossPerHour
            }
            if cursor >= state.lastExerciseAt.addingTimeInterval(rules.inactivityGraceHours * 3600) {
                healthLossRate += rules.inactivityHealthLossPerHour
            }

            var appliedHours = hours
            if healthLossRate > 0, state.health - healthLossRate * hours <= 0 {
                appliedHours = state.health / healthLossRate
                next = cursor.addingTimeInterval(appliedHours * 3600)
            }

            state.hunger += (sleeping ? rules.sleepingHungerPerHour : rules.awakeHungerPerHour) * appliedHours
            if sleeping {
                state.stamina = min(rules.maximumStamina, state.stamina + rules.sleepingStaminaRecoveryPerHour * appliedHours)
            } else {
                state.stamina = max(0, state.stamina - rules.awakeStaminaLossPerHour * appliedHours)
            }
            state.health = max(0, state.health - healthLossRate * appliedHours)
            state.lastUpdatedAt = next
            cursor = next

            if state.health <= 0 {
                state.diedAt = cursor
                state.sleepUntil = nil
                state.longestLifetime = max(state.longestLifetime, state.age(at: cursor))
            }
        }
    }
}
