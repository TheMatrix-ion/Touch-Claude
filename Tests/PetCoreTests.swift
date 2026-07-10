import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

@main
struct PetCoreTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    static let engine = PetEngine(calendar: calendar)
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--store-worker" {
            try runStoreWorker(
                directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                iterations: Int(CommandLine.arguments[3]) ?? 0
            )
            return
        }
        try testTokenRulesAndWork()
        try testFeedQuotaAndReset()
        try testNaturalAdvanceAndSleep()
        try testStarvationAndDeath()
        try testNeglectPenalties()
        try testHatch()
        try testStoreRoundTripAndPermissions()
        try testStoreConcurrency()
        try testStoreCrossProcessLock()
        try testCorruptStoreIsPreserved()
        try testTranscriptUsageAggregation()
        try testCLIAndStopHookIdempotence()
        try testFirstStopTimestampSkew()
        try testPetConditionLabels()
        try testClockRollbackDoesNotMovePetBackwards()
        try testAnswerLedgerSurvivesRehatch()
        try testLateTokensStayOnOriginalDayCap()
        try testAnswerLedgerIsBounded()
        try testLargeHungerDebtNeedsMultipleMeals()
        try testCorruptPendingEventDoesNotBlockQueue()
        print("PetCoreTests: all tests passed")
    }

    static func testTokenRulesAndWork() throws {
        var state = engine.hatch(at: start)
        state.health = 90
        let usage = AnswerUsage(
            id: "session:prompt-1",
            completedAt: start,
            inputTokens: 0,
            outputTokens: 30_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let result = try engine.completeAnswer(&state, usage: usage, at: start)
        try expectApprox(result.effectiveTokens, 30_000)
        try expectApprox(result.hungerAdded, 1)
        try expectApprox(result.staminaSpent, 6.5)
        try expectApprox(result.healthAdded, 0.5)
        try expectApprox(state.hunger, 21)

        let duplicate = try engine.completeAnswer(&state, usage: usage, at: start)
        try expect(duplicate.duplicate, "duplicate answer must be ignored")
        try expectApprox(state.hunger, 21)

        let expandedUsage = AnswerUsage(
            id: usage.id,
            completedAt: start,
            inputTokens: 0,
            outputTokens: 60_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let late = try engine.completeAnswer(&state, usage: expandedUsage, at: start)
        try expect(late.duplicate, "late token settlement must not create another work event")
        try expectApprox(late.effectiveTokens, 30_000)
        try expectApprox(late.hungerAdded, 1)
        try expectApprox(late.staminaSpent, 1.5)
        try expect(state.daily.workEvents == 1, "late token settlement must not increment work count")

        var healthy = engine.hatch(at: start)
        _ = try engine.completeAnswer(&healthy, usage: usage, at: start)
        try expectApprox(healthy.daily.workHealthGained, 0)

        let huge = AnswerUsage(
            id: "session:prompt-2",
            completedAt: start,
            inputTokens: 34_900,
            outputTokens: 352_000,
            cacheCreationTokens: 2_900_000,
            cacheReadTokens: 169_500_000
        )
        let heavyResult = try engine.completeAnswer(&state, usage: huge, at: start)
        try expectApprox(heavyResult.effectiveTokens, 4_473_980)
        try expectApprox(state.daily.tokenHungerAdded, 150)
        try expect(state.hunger > 100, "hunger debt must remain above the starving threshold")
    }

    static func testFeedQuotaAndReset() throws {
        var state = engine.hatch(at: start)
        state.hunger = 100
        _ = try engine.feed(&state, at: start)
        _ = try engine.feed(&state, at: start)
        let third = try engine.feed(&state, at: start)
        try expect(third.freeFeedsRemaining == 0, "third feed must consume final free meal")
        try expectApprox(state.hunger, 10)

        do {
            _ = try engine.feed(&state, at: start)
            throw TestFailure.assertion("fourth feed should fail")
        } catch PetActionError.noFreeFeedRemaining {}

        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        state.hunger = 40
        let resetFeed = try engine.feed(&state, at: nextDay)
        try expect(resetFeed.freeFeedsRemaining == 2, "daily free meals must reset at midnight")

        state.hunger = 5
        let usedBefore = state.daily.freeFeedsUsed
        do {
            _ = try engine.feed(&state, at: nextDay)
            throw TestFailure.assertion("feeding below threshold should fail")
        } catch PetActionError.notHungry {}
        try expect(state.daily.freeFeedsUsed == usedBefore, "refused feed must not consume quota")
    }

    static func testNaturalAdvanceAndSleep() throws {
        var awake = engine.hatch(at: start)
        engine.advance(&awake, to: start.addingTimeInterval(10 * 3600), passage: .online)
        try expectApprox(awake.hunger, 25)
        try expectApprox(awake.stamina, 80)

        var sleeping = engine.hatch(at: start)
        sleeping.stamina = 0
        try engine.sleep(&sleeping, at: start)
        engine.advance(&sleeping, to: start.addingTimeInterval(10 * 3600), passage: .online)
        try expect(sleeping.sleepUntil == nil, "manual sleep must auto-wake after eight hours")
        try expectApprox(sleeping.hunger, 23)
        try expectApprox(sleeping.stamina, 96)

        var offline = engine.hatch(at: start)
        offline.stamina = 0
        engine.advance(&offline, to: start.addingTimeInterval(12 * 3600), passage: .offline)
        try expectApprox(offline.hunger, 23)
        try expectApprox(offline.stamina, 100)
        try expect(offline.awakeSince == offline.lastUpdatedAt, "offline time must end rested and awake")
    }

    static func testStarvationAndDeath() throws {
        var starving = engine.hatch(at: start)
        starving.hunger = 99
        starving.health = 10
        engine.advance(&starving, to: start.addingTimeInterval(4 * 3600), passage: .online)
        try expectApprox(starving.hunger, 101)
        try expectApprox(starving.health, 6)

        _ = try engine.feed(&starving, at: start.addingTimeInterval(4 * 3600))
        try expect(starving.hunger < 100, "feeding must rescue a starving pet")

        var dying = engine.hatch(at: start)
        dying.hunger = 100
        dying.health = 1
        engine.advance(&dying, to: start.addingTimeInterval(3600), passage: .online)
        try expect(dying.isDead, "health reaching zero must kill the pet")
        try expectApprox(dying.age(at: start.addingTimeInterval(10 * 3600)), 1800)
    }

    static func testNeglectPenalties() throws {
        var tired = engine.hatch(at: start)
        tired.health = 10
        tired.awakeSince = start.addingTimeInterval(-20 * 3600)
        engine.advance(&tired, to: start.addingTimeInterval(2 * 3600), passage: .online)
        try expectApprox(tired.health, 9)

        var inactive = engine.hatch(at: start)
        inactive.health = 10
        inactive.lastExerciseAt = start.addingTimeInterval(-36 * 3600)
        engine.advance(&inactive, to: start.addingTimeInterval(10 * 3600), passage: .online)
        try expectApprox(inactive.health, 9)
    }

    static func testHatch() throws {
        var state = engine.hatch(at: start)
        state.health = 0
        state.diedAt = start.addingTimeInterval(5 * 3600)
        let oldID = state.id
        try engine.rehatch(&state, at: start.addingTimeInterval(6 * 3600))
        try expect(state.id != oldID, "hatch must create a new pet")
        try expect(state.generation == 2, "hatch must advance generation")
        try expectApprox(state.longestLifetime, 5 * 3600)
    }

    static func testStoreRoundTripAndPermissions() throws {
        let directory = try temporaryDirectory(named: "round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PetStore(directory: directory, engine: engine)

        let fed = try store.transaction(at: start) { state, engine in
            state.hunger = 40
            return try engine.feed(&state, at: start)
        }
        try expectApprox(fed.hungerAfter, 10)
        let loaded = try store.snapshot()
        try expectApprox(loaded?.hunger ?? -1, 10)

        let directoryMode = try posixMode(at: directory)
        let stateMode = try posixMode(at: store.stateURL)
        let lockMode = try posixMode(at: store.lockURL)
        try expect(directoryMode == 0o700, "pet directory must be mode 0700")
        try expect(stateMode == 0o600, "pet state must be mode 0600")
        try expect(lockMode == 0o600, "pet lock must be mode 0600")

        let override = PetStore.defaultDirectory(environment: [PetStore.dataDirectoryEnvironmentKey: directory.path])
        try expect(override.standardizedFileURL == directory.standardizedFileURL, "test data directory override must be honored")
    }

    static func testStoreConcurrency() throws {
        let directory = try temporaryDirectory(named: "concurrency")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PetStore(directory: directory, engine: engine)
        _ = try store.advance(at: start)

        let queue = DispatchQueue(label: "pet-store-tests", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = LockedErrors()
        for _ in 0..<40 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try store.transaction(at: start) { state, _ in
                        state.hunger += 1
                    }
                } catch {
                    failures.append(error)
                }
            }
        }
        group.wait()
        try expect(failures.values.isEmpty, "concurrent state transactions failed: \(failures.values)")
        let state = try store.snapshot()
        try expectApprox(state?.hunger ?? -1, 60)
    }

    static func testStoreCrossProcessLock() throws {
        let directory = try temporaryDirectory(named: "cross-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PetStore(directory: directory, engine: engine)
        _ = try store.advance(at: start)

        let workers = (0..<2).map { _ -> Process in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--store-worker", directory.path, "50"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        for worker in workers { try worker.run() }
        for worker in workers { worker.waitUntilExit() }
        try expect(workers.allSatisfy { $0.terminationStatus == 0 }, "cross-process workers must succeed")
        let state = try store.snapshot()
        try expectApprox(state?.hunger ?? -1, 120)
    }

    static func runStoreWorker(directory: URL, iterations: Int) throws {
        let store = PetStore(directory: directory, engine: engine)
        for _ in 0..<iterations {
            _ = try store.transaction(at: start) { state, _ in
                state.hunger += 1
            }
        }
    }

    static func testCorruptStoreIsPreserved() throws {
        let directory = try temporaryDirectory(named: "corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PetStore(directory: directory, engine: engine)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("not valid json".utf8)
        try original.write(to: store.stateURL)

        do {
            _ = try store.advance(at: start)
            throw TestFailure.assertion("corrupt pet state should fail explicitly")
        } catch is PetStoreError {}
        let preserved = try Data(contentsOf: store.stateURL)
        try expect(preserved == original, "corrupt state must be left untouched")
    }

    static func testTranscriptUsageAggregation() throws {
        let root = try temporaryDirectory(named: "transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let subagents = root.appendingPathComponent("session/subagents", isDirectory: true)
        let nested = subagents.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:00.000Z", promptID: "prompt-1"),
            assistant(timestamp: "2027-01-15T08:00:01.000Z", messageID: "main-1", input: 100, output: 10, cacheCreate: 20, cacheRead: 1_000),
            assistant(timestamp: "2027-01-15T08:00:02.000Z", messageID: "main-1", input: 100, output: 30, cacheCreate: 20, cacheRead: 1_000),
            assistant(timestamp: "2027-01-15T08:00:03.000Z", messageID: "sidechain", input: 0, output: 9_999, cacheCreate: 0, cacheRead: 0, sidechain: true),
            record(type: "user", timestamp: "2027-01-15T08:10:00.000Z", promptID: "prompt-2"),
            assistant(timestamp: "2027-01-15T08:10:01.000Z", messageID: "other", input: 0, output: 500, cacheCreate: 0, cacheRead: 0)
        ], to: transcript)

        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:04.000Z", promptID: "prompt-1", sidechain: true),
            assistant(timestamp: "2027-01-15T08:00:05.000Z", messageID: "agent-1", input: 50, output: 20, cacheCreate: 10, cacheRead: 200, sidechain: true),
            assistant(timestamp: "2027-01-15T08:00:06.000Z", messageID: "agent-1", input: 50, output: 40, cacheCreate: 10, cacheRead: 200, sidechain: true),
            record(type: "user", timestamp: "2027-01-15T08:10:02.000Z", promptID: "prompt-2", sidechain: true),
            assistant(timestamp: "2027-01-15T08:10:03.000Z", messageID: "agent-other", input: 0, output: 700, cacheCreate: 0, cacheRead: 0, sidechain: true)
        ], to: subagents.appendingPathComponent("agent-direct.jsonl"))

        // Internal agents use their own prompt IDs. Their file start time maps
        // them back to the active top-level prompt.
        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:07.000Z", promptID: "internal-prompt", sidechain: true),
            assistant(timestamp: "2027-01-15T08:00:08.000Z", messageID: "nested-1", input: 25, output: 15, cacheCreate: 5, cacheRead: 100, sidechain: true)
        ], to: nested.appendingPathComponent("agent-nested.jsonl"))

        let usage = try TranscriptUsageScanner().usage(transcriptURL: transcript, promptID: "prompt-1")
        try expect(usage == TokenUsageCounters(
            inputTokens: 175,
            outputTokens: 85,
            cacheCreationTokens: 35,
            cacheReadTokens: 1_300
        ), "main, direct-agent, and nested-agent usage should be aggregated once: \(usage)")
    }

    static func testCLIAndStopHookIdempotence() throws {
        let root = try temporaryDirectory(named: "cli-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("fixture/session.jsonl")
        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:00.000Z", promptID: "prompt-1"),
            assistant(timestamp: "2027-01-15T08:00:01.000Z", messageID: "answer", input: 0, output: 30_000, cacheCreate: 0, cacheRead: 0)
        ], to: transcript)

        var output: [String] = []
        var errors: [String] = []
        var clock = start
        let cli = PetCLI(
            dataDirectory: root.appendingPathComponent("data", isDirectory: true),
            engine: engine,
            now: { clock },
            output: { output.append($0) },
            errorOutput: { errors.append($0) }
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "transcript_path": transcript.path,
            "stop_hook_active": false
        ])

        try expect(cli.run(arguments: ["_record-stop"], standardInput: payload) == EXIT_SUCCESS, "Stop hook must succeed")
        try expect(cli.run(arguments: ["_record-stop"], standardInput: payload) == EXIT_SUCCESS, "replayed Stop hook must succeed")
        let inferredEvent = try StopHookEvent.parse(payload, completedAt: start)
        try expect(inferredEvent?.promptID == "prompt-1", "Stop hook must infer omitted prompt_id from transcript metadata")
        var state = try cli.store.snapshot()
        try expect(state?.daily.workEvents == 1, "one prompt must create one work event")
        try expectApprox(state?.hunger ?? -1, 20)
        try expect(PokeSignal.pending(in: cli.store.directory).count == 1, "one prompt must queue one visual bounce")

        let initialScanErrors = cli.stopQueue.processDue(at: start)
        try expect(initialScanErrors.isEmpty, "initial async token scan should succeed: \(initialScanErrors)")
        state = try cli.store.snapshot()
        try expectApprox(state?.hunger ?? -1, 21)

        // A later snapshot may include async subagent/output tokens; it adjusts
        // the original charge without producing another work event or jump.
        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:00.000Z", promptID: "prompt-1"),
            assistant(timestamp: "2027-01-15T08:00:01.000Z", messageID: "answer", input: 0, output: 60_000, cacheCreate: 0, cacheRead: 0)
        ], to: transcript)
        let dueErrors = cli.stopQueue.processDue(at: start.addingTimeInterval(2))
        try expect(dueErrors.isEmpty, "delayed token rescan should succeed: \(dueErrors)")
        state = try cli.store.snapshot()
        try expectApprox(state?.hunger ?? -1, 22, tolerance: 0.001)
        try expect(state?.daily.workEvents == 1, "token rescan must not create another work event")
        try expect(PokeSignal.pending(in: cli.store.directory).count == 1, "token rescan must not queue another bounce")

        clock = start.addingTimeInterval(3)
        try expect(cli.run(arguments: ["status", "--json"]) == EXIT_SUCCESS, "status should succeed")
        try expect(output.last?.contains("\"dailyWorkEvents\" : 1") == true, "JSON status should expose today's work count")
        try expect(cli.run(arguments: ["feed"]) == EXIT_SUCCESS, "feed should succeed")
        try expect(cli.run(arguments: ["sleep"]) == EXIT_SUCCESS, "sleep should succeed")
        try expect(cli.run(arguments: ["wake"]) == EXIT_SUCCESS, "wake should succeed")
        try expect(cli.run(arguments: ["view", "show"]) == EXIT_SUCCESS, "view show should succeed")
        try expect(ModeSignal.read(in: cli.store.directory).mode == .wake, "view mode must use isolated data directory")
        try expect(cli.run(arguments: ["jump"]) == EXIT_FAILURE, "manual jump must not exist")
        try expect(!errors.isEmpty, "invalid manual jump should print usage")

        _ = try cli.store.transaction(at: clock) { state, _ in
            state.health = 0
            state.diedAt = clock
        }
        try expect(cli.run(arguments: ["hatch"]) == EXIT_SUCCESS, "hatch should revive a dead pet")
        let hatched = try cli.store.snapshot()
        try expect(hatched?.generation == 2, "CLI hatch must increment generation")

        let nestedPayload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "prompt_id": "prompt-agent",
            "transcript_path": transcript.path,
            "agent_id": "agent-1"
        ])
        let nestedEvent = try StopHookEvent.parse(nestedPayload, completedAt: start)
        try expect(nestedEvent == nil, "subagent Stop must not count separately")

        let activePayload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "transcript_path": transcript.path,
            "stop_hook_active": true
        ])
        let activeEvent = try StopHookEvent.parse(activePayload, completedAt: start)
        try expect(activeEvent?.promptID == "prompt-1", "stop_hook_active must rely on prompt idempotency, not be dropped")
    }

    static func testPetConditionLabels() throws {
        var state = engine.hatch(at: start)
        try expect(
            PetCondition.touchBarMetrics(from: state) == "♥100  🍖80  ⚡100",
            "Touch Bar must show health, hunger, and stamina"
        )
        try expectApprox(PetPresentation.hungerLevel(fromDebt: 0), 100)
        try expectApprox(PetPresentation.hungerLevel(fromDebt: 20), 80)
        try expectApprox(PetPresentation.hungerLevel(fromDebt: 100), 0)
        try expectApprox(PetPresentation.hungerLevel(fromDebt: 150), 0)
        try expect(PetCondition.derive(from: state, at: start) == .healthy, "healthy condition")

        state.hunger = 70
        try expect(PetCondition.derive(from: state, at: start) == .hungry, "hungry condition")
        state.hunger = 20
        state.stamina = 10
        try expect(PetCondition.derive(from: state, at: start) == .tired, "tired condition")
        state.stamina = 100
        state.health = 20
        try expect(PetCondition.derive(from: state, at: start) == .critical, "critical condition")
        state.health = 100
        try engine.sleep(&state, at: start)
        try expect(PetCondition.derive(from: state, at: start) == .sleeping, "sleeping condition")
        try expect(
            PetCondition.touchBarText(from: state, at: start) == "sleeping",
            "sleeping Touch Bar must hide all three metrics"
        )
        state.sleepUntil = nil
        state.hunger = 100
        try expect(PetCondition.derive(from: state, at: start) == .starving, "starving condition")
        state.health = 0
        state.diedAt = start
        try expect(PetCondition.derive(from: state, at: start) == .dead, "dead condition")
    }

    static func testFirstStopTimestampSkew() throws {
        let root = try temporaryDirectory(named: "first-stop-skew")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:00.000Z", promptID: "first"),
            assistant(timestamp: "2027-01-15T08:00:00.010Z", messageID: "first-answer", input: 0, output: 1_000, cacheCreate: 0, cacheRead: 0)
        ], to: transcript)
        let queue = StopEventQueue(dataDirectory: root.appendingPathComponent("data"), engine: engine)
        let event = StopHookEvent(
            sessionID: "session",
            promptID: "first",
            transcriptPath: transcript.path,
            completedAt: start
        )
        let result = try queue.record(event, at: start.addingTimeInterval(0.1))
        try expect(!result.duplicate, "the first answer must not look stale because state creation is milliseconds later")
        let state = try queue.store.snapshot()
        try expect(state?.daily.workEvents == 1, "the first answer must hatch and settle")
    }

    static func testClockRollbackDoesNotMovePetBackwards() throws {
        let later = start.addingTimeInterval(3_600)

        var sleeping = engine.hatch(at: start)
        engine.advance(&sleeping, to: later, passage: .online)
        try engine.sleep(&sleeping, at: start)
        try expect(sleeping.sleepUntil == later.addingTimeInterval(8 * 3_600), "sleep must start from monotonic pet time")
        try engine.wake(&sleeping, at: start)
        try expect(sleeping.awakeSince == later, "wake must not move awake time backwards")

        var working = engine.hatch(at: start)
        engine.advance(&working, to: later, passage: .online)
        let usage = AnswerUsage(
            id: "rollback-work",
            completedAt: later,
            inputTokens: 0,
            outputTokens: 1_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        _ = try engine.completeAnswer(&working, usage: usage, at: start)
        try expect(working.lastExerciseAt == later, "work must not move exercise time backwards")

        var dead = engine.hatch(at: start)
        dead.health = 0
        dead.diedAt = later
        dead.lastUpdatedAt = later
        try engine.rehatch(&dead, at: start)
        try expect(dead.bornAt == later, "rehatch must not predate the prior death")
    }

    static func testAnswerLedgerSurvivesRehatch() throws {
        var state = engine.hatch(at: start)
        let first = AnswerUsage(
            id: "session:original",
            completedAt: start,
            inputTokens: 0,
            outputTokens: 30_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        _ = try engine.completeAnswer(&state, usage: first, at: start)
        state.hunger = 100
        _ = try engine.feed(&state, at: start)
        _ = try engine.feed(&state, at: start)
        _ = try engine.feed(&state, at: start)
        try expect(state.daily.freeFeedsUsed == 3, "setup must use all free meals")

        let hatchTime = start.addingTimeInterval(1)
        state.health = 0
        state.diedAt = hatchTime
        state.lastUpdatedAt = hatchTime
        try engine.rehatch(&state, at: hatchTime)
        try expect(state.daily.freeFeedsUsed == 3, "same-day rehatch must not refresh free meals")

        let hungerBefore = state.hunger
        let replay = AnswerUsage(
            id: first.id,
            completedAt: hatchTime,
            inputTokens: 0,
            outputTokens: 60_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let result = try engine.completeAnswer(&state, usage: replay, at: hatchTime)
        try expect(result.duplicate, "old answer replay must stay duplicate after rehatch")
        try expectApprox(result.effectiveTokens, 0)
        try expectApprox(state.hunger, hungerBefore)
        try expect(state.daily.workEvents == 1, "old answer must not become work for the new generation")
    }

    static func testLateTokensStayOnOriginalDayCap() throws {
        let dayStart = calendar.startOfDay(for: start)
        let midnight = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let completion = midnight.addingTimeInterval(-30)
        var state = engine.hatch(at: completion)

        let fullDay = AnswerUsage(
            id: "session:before-midnight",
            completedAt: completion,
            inputTokens: 0,
            outputTokens: 4_500_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let first = try engine.completeAnswer(&state, usage: fullDay, at: completion)
        try expectApprox(first.hungerAdded, 150)

        let late = AnswerUsage(
            id: fullDay.id,
            completedAt: completion,
            inputTokens: 0,
            outputTokens: 9_000_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let lateResult = try engine.completeAnswer(
            &state,
            usage: late,
            at: midnight.addingTimeInterval(30)
        )
        try expectApprox(lateResult.hungerAdded, 0)
        try expectApprox(state.daily.tokenHungerAdded, 0)
        try expectApprox(state.daily.effectiveTokens, 0)

        let nextDay = AnswerUsage(
            id: "session:after-midnight",
            completedAt: midnight.addingTimeInterval(30),
            inputTokens: 0,
            outputTokens: 30_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let nextResult = try engine.completeAnswer(
            &state,
            usage: nextDay,
            at: midnight.addingTimeInterval(30)
        )
        try expectApprox(nextResult.hungerAdded, 1)
        try expectApprox(state.daily.tokenHungerAdded, 1)
    }

    static func testAnswerLedgerIsBounded() throws {
        var state = engine.hatch(at: start)
        for index in 0...engine.rules.processedAnswerLimit {
            let usage = AnswerUsage(
                id: "session:answer-\(index)",
                completedAt: start,
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
            _ = try engine.completeAnswer(&state, usage: usage, at: start)
        }
        try expect(
            state.processedAnswerIDs.count == engine.rules.processedAnswerLimit,
            "answer ledger must remain bounded"
        )
        let replay = AnswerUsage(
            id: "session:answer-\(engine.rules.processedAnswerLimit)",
            completedAt: start,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        let result = try engine.completeAnswer(&state, usage: replay, at: start)
        try expect(result.duplicate, "recent ledger entry must remain duplicate")
        try expectApprox(result.effectiveTokens, 0)
        try expect(
            state.daily.workEvents == engine.rules.processedAnswerLimit + 1,
            "replay must not create another work event"
        )
    }

    static func testLargeHungerDebtNeedsMultipleMeals() throws {
        var state = engine.hatch(at: start)
        state.hunger = 190
        _ = try engine.feed(&state, at: start)
        try expectApprox(state.hunger, 160)
        try expect(PetCondition.derive(from: state, at: start) == .starving, "one meal must not erase large hunger debt")
    }

    static func testCorruptPendingEventDoesNotBlockQueue() throws {
        let root = try temporaryDirectory(named: "corrupt-pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        try writeJSONLines([
            record(type: "user", timestamp: "2027-01-15T08:00:00.000Z", promptID: "one"),
            assistant(timestamp: "2027-01-15T08:00:01.000Z", messageID: "one-answer", input: 0, output: 30_000, cacheCreate: 0, cacheRead: 0),
            record(type: "user", timestamp: "2027-01-15T08:01:00.000Z", promptID: "two"),
            assistant(timestamp: "2027-01-15T08:01:01.000Z", messageID: "two-answer", input: 0, output: 30_000, cacheCreate: 0, cacheRead: 0)
        ], to: transcript)
        let queue = StopEventQueue(dataDirectory: root.appendingPathComponent("data"), engine: engine)
        _ = try queue.record(StopHookEvent(sessionID: "s", promptID: "one", transcriptPath: transcript.path, completedAt: start), at: start)
        _ = try queue.record(StopHookEvent(sessionID: "s", promptID: "two", transcriptPath: transcript.path, completedAt: start), at: start)

        let pending = try FileManager.default.contentsOfDirectory(
            at: queue.eventsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        try expect(pending.count == 2, "setup must create two pending events")
        try Data("broken".utf8).write(to: pending[0], options: .atomic)

        let errors = queue.processDue(at: start)
        try expect(errors.count == 1, "corrupt event should be reported once")
        let state = try queue.store.snapshot()
        try expectApprox(state?.daily.effectiveTokens ?? -1, 30_000)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: queue.eventsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.hasPrefix("corrupt-") }
        try expect(quarantined.count == 1, "corrupt event should be quarantined")
    }

    static func record(
        type: String,
        timestamp: String,
        promptID: String,
        sidechain: Bool? = nil
    ) -> [String: Any] {
        var value: [String: Any] = ["type": type, "timestamp": timestamp, "promptId": promptID]
        if let sidechain { value["isSidechain"] = sidechain }
        return value
    }

    static func assistant(
        timestamp: String,
        messageID: String,
        input: Int,
        output: Int,
        cacheCreate: Int,
        cacheRead: Int,
        sidechain: Bool? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_creation_input_tokens": cacheCreate,
                    "cache_read_input_tokens": cacheRead
                ]
            ]
        ]
        if let sidechain { value["isSidechain"] = sidechain }
        return value
    }

    static func writeJSONLines(_ values: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for value in values {
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    static func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTouchBarTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.assertion(message) }
    }

    static func expectApprox(_ actual: Double, _ expected: Double, tolerance: Double = 0.0001) throws {
        if abs(actual - expected) > tolerance {
            throw TestFailure.assertion("expected \(expected), got \(actual)")
        }
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
