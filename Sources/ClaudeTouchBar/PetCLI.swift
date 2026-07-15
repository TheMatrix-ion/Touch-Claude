import Foundation

enum PetPresentation {
    static func hungerLevel(fromDebt hungerDebt: Double) -> Double {
        min(100, max(0, 100 - hungerDebt))
    }
}

enum PetExpression: Equatable {
    case normal
    case distressed
    case sleeping
}

enum PetCondition: String, Codable {
    case healthy
    case hungry
    case tired
    case critical
    case sleeping
    case starving
    case dead

    var expression: PetExpression {
        switch self {
        case .healthy, .dead:
            return .normal
        case .hungry, .tired, .critical, .starving:
            return .distressed
        case .sleeping:
            return .sleeping
        }
    }

    static func derive(from state: PetState, at now: Date) -> PetCondition {
        if state.isDead { return .dead }
        if state.sleepUntil.map({ $0 > now }) == true { return .sleeping }
        if state.hunger >= 100 { return .starving }
        if state.health < 30 { return .critical }
        if state.hunger >= 70 { return .hungry }
        if state.stamina < 20 { return .tired }
        return .healthy
    }

    static func touchBarMetrics(from state: PetState) -> String {
        let health = Int(state.health.rounded())
        let hunger = Int(PetPresentation.hungerLevel(fromDebt: state.hunger).rounded())
        let stamina = Int(state.stamina.rounded())
        return "♥\(health)  🍖\(hunger)  ⚡\(stamina)"
    }

    static func touchBarText(from state: PetState, at now: Date) -> String {
        derive(from: state, at: now) == .sleeping ? "sleeping" : touchBarMetrics(from: state)
    }
}

private struct PetStatusSnapshot: Encodable {
    let generation: Int
    let condition: PetCondition
    let alive: Bool
    let ageSeconds: Int
    let health: Double
    let hunger: Double
    let stamina: Double
    let sleepingUntil: Date?
    let freeFeedsRemaining: Int
    let dailyWorkEvents: Int
    let dailyEffectiveTokens: Double
    let dailyTokenHunger: Double
    let nextDailyReset: Date
    let longestLifetimeSeconds: Int
}

struct PetCLI {
    let store: PetStore
    let stopQueue: StopEventQueue
    let now: () -> Date
    let output: (String) -> Void
    let errorOutput: (String) -> Void

    init(
        dataDirectory: URL = PetStore.defaultDirectory(),
        engine: PetEngine = PetEngine(),
        now: @escaping () -> Date = Date.init,
        output: @escaping (String) -> Void = { print($0) },
        errorOutput: @escaping (String) -> Void = { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
    ) {
        self.store = PetStore(directory: dataDirectory, engine: engine)
        self.stopQueue = StopEventQueue(dataDirectory: dataDirectory, engine: engine)
        self.now = now
        self.output = output
        self.errorOutput = errorOutput
    }

    func run(arguments: [String], standardInput: Data? = nil) -> Int32 {
        guard let command = arguments.first else {
            errorOutput(Self.usage)
            return EXIT_FAILURE
        }

        if command == "_record-stop" {
            return recordStop(input: standardInput ?? FileHandle.standardInput.readDataToEndOfFile())
        }

        let timestamp = now()
        for error in stopQueue.processDue(at: timestamp) { logHookError(error) }

        do {
            switch command {
            case "status":
                let allowed = Set(["--json"])
                guard Set(arguments.dropFirst()).isSubset(of: allowed) else { throw CLIError.usage }
                let state = try store.advance(at: timestamp)
                try printStatus(state, at: timestamp, asJSON: arguments.contains("--json"))
            case "feed":
                guard arguments.count == 1 else { throw CLIError.usage }
                let result = try store.transaction(at: timestamp) { state, engine in
                    try engine.feed(&state, at: timestamp)
                }
                let hungerBefore = PetPresentation.hungerLevel(fromDebt: result.hungerBefore)
                let hungerAfter = PetPresentation.hungerLevel(fromDebt: result.hungerAfter)
                output("clawd ate: hunger \(number(hungerBefore)) → \(number(hungerAfter)); free feeds left today: \(result.freeFeedsRemaining)")
            case "sleep":
                guard arguments.count == 1 else { throw CLIError.usage }
                try store.transaction(at: timestamp) { state, engine in
                    try engine.sleep(&state, at: timestamp)
                }
                output("clawd is sleeping (auto-wakes after at most 8 hours)")
            case "wake":
                guard arguments.count == 1 else { throw CLIError.usage }
                try store.transaction(at: timestamp) { state, engine in
                    try engine.wake(&state, at: timestamp)
                }
                output("clawd is awake")
            case "hatch":
                guard arguments.count == 1 else { throw CLIError.usage }
                try store.transaction(at: timestamp) { state, engine in
                    try engine.rehatch(&state, at: timestamp)
                }
                output("a new clawd hatched")
            case "view":
                try setView(arguments: Array(arguments.dropFirst()))
            case "help", "--help", "-h":
                output(Self.usage)
            default:
                throw CLIError.usage
            }
            return EXIT_SUCCESS
        } catch CLIError.usage {
            errorOutput(Self.usage)
        } catch {
            errorOutput("clawd: \(error)")
        }
        return EXIT_FAILURE
    }

    private func recordStop(input: Data) -> Int32 {
        do {
            guard let event = try StopHookEvent.parse(input, completedAt: now()) else {
                return EXIT_SUCCESS
            }
            _ = try stopQueue.record(event, at: now())
        } catch {
            // A hook must never turn a successful Claude response into a failed
            // turn. Persist diagnostic metadata locally and always return zero.
            logHookError(error)
        }
        return EXIT_SUCCESS
    }

    private func printStatus(_ state: PetState, at now: Date, asJSON: Bool) throws {
        let snapshot = PetStatusSnapshot(
            generation: state.generation,
            condition: .derive(from: state, at: now),
            alive: !state.isDead,
            ageSeconds: Int(state.age(at: now)),
            health: state.health,
            hunger: PetPresentation.hungerLevel(fromDebt: state.hunger),
            stamina: state.stamina,
            sleepingUntil: state.sleepUntil,
            freeFeedsRemaining: max(0, store.engine.rules.freeFeedsPerDay - state.daily.freeFeedsUsed),
            dailyWorkEvents: state.daily.workEvents,
            dailyEffectiveTokens: state.daily.effectiveTokens,
            dailyTokenHunger: state.daily.tokenHungerAdded,
            nextDailyReset: state.daily.nextResetAt,
            longestLifetimeSeconds: Int(state.longestLifetime)
        )

        if asJSON {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            output(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
            return
        }

        output("clawd #\(snapshot.generation) — \(snapshot.condition.rawValue), age \(duration(snapshot.ageSeconds))")
        output("health \(number(snapshot.health))/100  hunger \(number(snapshot.hunger))/100  stamina \(number(snapshot.stamina))/100")
        output("today: \(snapshot.dailyWorkEvents) work events, \(Int(snapshot.dailyEffectiveTokens.rounded())) effective tokens, \(snapshot.freeFeedsRemaining)/3 free feeds left")
        if !snapshot.alive { output("run `clawd hatch` to start again") }
    }

    private func setView(arguments: [String]) throws {
        guard arguments.count == 1 else { throw CLIError.usage }
        let mode: Mode
        let label: String
        switch arguments[0] {
        case "show": mode = .wake; label = "always shown"
        case "hide": mode = .sleep; label = "hidden"
        case "auto": mode = .auto; label = "following Claude Code"
        default: throw CLIError.usage
        }
        try ModeSignal.write(mode, in: store.directory)
        output("clawd view: \(label)")
    }

    private func logHookError(_ error: Error) {
        let url = store.directory.appendingPathComponent("hook-errors.log", isDirectory: false)
        let line = "\(ISO8601DateFormatter().string(from: now())) \(error)\n"
        do {
            try FileManager.default.createDirectory(
                at: store.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: store.directory.path
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // Hook diagnostics are deliberately best effort.
        }
    }

    private func number(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
    }

    private func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private enum CLIError: Error { case usage }

    static let usage = """
    usage:
      clawd status [--json]
      clawd feed
      clawd sleep
      clawd wake
      clawd hatch
      clawd view show|hide|auto
    """
}
