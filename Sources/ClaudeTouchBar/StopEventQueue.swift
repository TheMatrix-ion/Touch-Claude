import Darwin
import Foundation

enum StopHookEventError: Error, CustomStringConvertible {
    case malformedInput
    case invalidEvent

    var description: String {
        switch self {
        case .malformedInput: return "Stop hook input is not a JSON object"
        case .invalidEvent: return "Stop hook input is missing required session, prompt, or transcript metadata"
        }
    }
}

struct StopHookEvent: Equatable {
    let sessionID: String
    let promptID: String
    let transcriptPath: String
    let completedAt: Date

    var answerID: String { "\(sessionID):\(promptID)" }

    /// Returns nil for nested-agent or recursive Stop events that must not count
    /// as an additional player question.
    static func parse(_ data: Data, completedAt: Date = Date()) throws -> StopHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StopHookEventError.malformedInput
        }
        guard object["hook_event_name"] as? String == "Stop" else { return nil }
        if let agentID = object["agent_id"] as? String, !agentID.isEmpty { return nil }

        guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let transcriptPath = object["transcript_path"] as? String, !transcriptPath.isEmpty
        else { throw StopHookEventError.invalidEvent }

        let explicitPromptID = object["prompt_id"] as? String
        let promptID: String
        if let explicitPromptID, !explicitPromptID.isEmpty {
            promptID = explicitPromptID
        } else if let inferred = try TranscriptUsageScanner().latestPromptID(
            transcriptURL: URL(fileURLWithPath: transcriptPath)
        ) {
            promptID = inferred
        } else {
            throw StopHookEventError.invalidEvent
        }

        return StopHookEvent(
            sessionID: sessionID,
            promptID: promptID,
            transcriptPath: transcriptPath,
            completedAt: completedAt
        )
    }
}

private struct PendingStopEvent: Codable {
    let sessionID: String
    let promptID: String
    let transcriptPath: String
    let completedAt: Date
    var attempts: Int
    var nextAttemptAt: Date

    init(_ event: StopHookEvent) {
        sessionID = event.sessionID
        promptID = event.promptID
        transcriptPath = event.transcriptPath
        completedAt = event.completedAt
        attempts = 0
        nextAttemptAt = event.completedAt
    }

    var answerID: String { "\(sessionID):\(promptID)" }
}

/// Keeps a prompt around briefly so token snapshots can be rescanned after
/// asynchronous and nested agents finish. Rescans only apply positive deltas;
/// they never produce another work event or another bounce.
struct StopEventQueue {
    private static let processLock = NSLock()
    private static let rescanOffsets: [TimeInterval] = [0, 2, 10, 60]

    let dataDirectory: URL
    let eventsDirectory: URL
    let lockURL: URL
    let store: PetStore
    let scanner: TranscriptUsageScanner

    init(
        dataDirectory: URL = PetStore.defaultDirectory(),
        engine: PetEngine = PetEngine(),
        scanner: TranscriptUsageScanner = TranscriptUsageScanner()
    ) {
        self.dataDirectory = dataDirectory.standardizedFileURL
        self.eventsDirectory = self.dataDirectory.appendingPathComponent("pending-stops", isDirectory: true)
        self.lockURL = self.dataDirectory.appendingPathComponent("pending-stops.lock", isDirectory: false)
        self.store = PetStore(directory: self.dataDirectory, engine: engine)
        self.scanner = scanner
    }

    @discardableResult
    func record(_ event: StopHookEvent, at now: Date = Date()) throws -> WorkResult {
        let (pending, isNew) = try enqueueOrLoad(event)
        // Keep the Claude Stop hook fast: record the one work event and bounce
        // immediately, then let the long-running helper parse token usage.
        let result = try settle(pending, usage: .zero, at: now)
        if !result.duplicate {
            try PokeSignal.enqueue(in: dataDirectory)
        }
        if isNew { try advanceSchedule(for: pending) }
        return result
    }

    /// Best-effort maintenance for the helper and public CLI commands. Errors
    /// are returned for logging but never prevent the pet UI from running.
    func processDue(at now: Date = Date()) -> [Error] {
        let due: [(URL, PendingStopEvent)]
        var errors: [Error]
        do {
            let loaded = try dueEvents(at: now)
            due = loaded.events
            errors = loaded.errors
        } catch {
            return [error]
        }

        for (url, event) in due {
            do {
                let result = try settle(event, usage: nil, at: now)
                if !result.duplicate { try PokeSignal.enqueue(in: dataDirectory) }
                try advanceSchedule(for: event, eventURL: url)
            } catch {
                errors.append(error)
                // Storage/transcript failures are retried on the normal schedule.
                try? advanceSchedule(for: event, eventURL: url)
            }
        }
        return errors
    }

    private func settle(
        _ event: PendingStopEvent,
        usage suppliedUsage: TokenUsageCounters?,
        at now: Date
    ) throws -> WorkResult {
        let usage = suppliedUsage ?? ((try? scanner.usage(
            transcriptURL: URL(fileURLWithPath: event.transcriptPath),
            promptID: event.promptID
        )) ?? .zero)
        let answer = usage.asAnswerUsage(id: event.answerID, completedAt: event.completedAt)
        // On the very first Stop event no pet file exists yet. Hatch at the
        // event timestamp (not a few milliseconds later at transaction start),
        // otherwise the first legitimate answer looks stale.
        return try store.transaction(at: event.completedAt) { state, engine in
            let result = try engine.completeAnswer(&state, usage: answer, at: event.completedAt)
            engine.advance(&state, to: now, passage: .online)
            return result
        }
    }

    private func enqueueOrLoad(_ event: StopHookEvent) throws -> (PendingStopEvent, Bool) {
        try withQueueLock {
            let url = eventURL(for: event.answerID)
            do {
                if let existing = try loadEvent(at: url) { return (existing, false) }
            } catch {
                try? quarantine(url)
            }
            let pending = PendingStopEvent(event)
            try saveEvent(pending, at: url)
            return (pending, true)
        }
    }

    private func dueEvents(at now: Date) throws -> (
        events: [(URL, PendingStopEvent)],
        errors: [Error]
    ) {
        try withQueueLock {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: eventsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return ([], []) }

            var events: [(URL, PendingStopEvent)] = []
            var errors: [Error] = []
            for url in urls
                .filter({ $0.pathExtension == "json" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            {
                do {
                    if let event = try loadEvent(at: url), event.nextAttemptAt <= now {
                        events.append((url, event))
                    }
                } catch {
                    errors.append(error)
                    try? quarantine(url)
                }
            }
            return (events, errors)
        }
    }

    private func quarantine(_ url: URL) throws {
        let destination = url.deletingPathExtension().appendingPathExtension(
            "corrupt-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private func advanceSchedule(for event: PendingStopEvent, eventURL explicitURL: URL? = nil) throws {
        try withQueueLock {
            let url = explicitURL ?? eventURL(for: event.answerID)
            guard var current = try loadEvent(at: url) else { return }
            // Another helper/CLI instance already advanced this snapshot.
            guard current.attempts == event.attempts else { return }

            if current.attempts >= Self.rescanOffsets.count {
                try FileManager.default.removeItem(at: url)
                return
            }
            current.nextAttemptAt = current.completedAt.addingTimeInterval(
                Self.rescanOffsets[current.attempts]
            )
            current.attempts += 1
            try saveEvent(current, at: url)
        }
    }

    private func eventURL(for answerID: String) -> URL {
        let encoded = Data(answerID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return eventsDirectory.appendingPathComponent("\(encoded).json", isDirectory: false)
    }

    private func loadEvent(at url: URL) throws -> PendingStopEvent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PendingStopEvent.self, from: Data(contentsOf: url))
    }

    private func saveEvent(_ event: PendingStopEvent, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(event).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func withQueueLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try FileManager.default.createDirectory(
            at: eventsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: dataDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: eventsDirectory.path
        )

        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw PetStoreError.cannotOpenLock(lockURL.path, errno) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw PetStoreError.cannotLock(lockURL.path, errno)
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}
