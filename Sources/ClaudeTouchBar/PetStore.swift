import Darwin
import Foundation

enum PetStoreError: Error, CustomStringConvertible {
    case cannotOpenLock(String, Int32)
    case cannotLock(String, Int32)
    case corruptState(String, Error)
    case unsupportedSchema(Int)
    case cannotWriteState(String, Error)

    var description: String {
        switch self {
        case .cannotOpenLock(let path, let code):
            return "cannot open pet-state lock at \(path): errno \(code)"
        case .cannotLock(let path, let code):
            return "cannot lock pet state at \(path): errno \(code)"
        case .corruptState(let path, let error):
            return "pet state at \(path) is unreadable; it was left untouched: \(error)"
        case .unsupportedSchema(let version):
            return "pet state uses unsupported schema version \(version)"
        case .cannotWriteState(let path, let error):
            return "cannot save pet state at \(path): \(error)"
        }
    }
}

/// Serializes all read/modify/write operations across the helper, CLI, and hook.
/// The lock file is never replaced; the JSON file is written atomically while
/// that stable lock is held.
struct PetStore {
    static let dataDirectoryEnvironmentKey = "CLAWD_DATA_DIR"
    private static let processLock = NSLock()

    let directory: URL
    let stateURL: URL
    let lockURL: URL
    let engine: PetEngine

    init(directory: URL = PetStore.defaultDirectory(), engine: PetEngine = PetEngine()) {
        self.directory = directory.standardizedFileURL
        self.stateURL = self.directory.appendingPathComponent("pet-state.json", isDirectory: false)
        self.lockURL = self.directory.appendingPathComponent("pet-state.lock", isDirectory: false)
        self.engine = engine
    }

    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[dataDirectoryEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-touchbar", isDirectory: true)
    }

    /// Loads or hatches a pet, advances time, runs one action, and persists the
    /// resulting state even when the action itself returns a gameplay error.
    func transaction<T>(
        at now: Date = Date(),
        passage: TimePassage = .online,
        _ action: (inout PetState, PetEngine) throws -> T
    ) throws -> T {
        try withExclusiveLock {
            var state = try loadUnlocked() ?? engine.hatch(at: now)
            engine.advance(&state, to: now, passage: passage)

            let result: Result<T, Error>
            do {
                result = .success(try action(&state, engine))
            } catch {
                result = .failure(error)
            }

            try saveUnlocked(state)
            return try result.get()
        }
    }

    func advance(at now: Date = Date(), passage: TimePassage = .online) throws -> PetState {
        try transaction(at: now, passage: passage) { state, _ in state }
    }

    /// A non-mutating snapshot for frequent UI refreshes. Missing state returns
    /// nil; malformed state remains an explicit error and is never overwritten.
    func snapshot() throws -> PetState? {
        try withExclusiveLock { try loadUnlocked() }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        PetStore.processLock.lock()
        defer { PetStore.processLock.unlock() }
        try prepareDirectory()
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw PetStoreError.cannotOpenLock(lockURL.path, errno)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        defer { Darwin.close(descriptor) }

        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw PetStoreError.cannotLock(lockURL.path, errno)
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
    }

    private func loadUnlocked() throws -> PetState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let state = try decoder.decode(PetState.self, from: data)
            guard state.schemaVersion == PetState.currentSchemaVersion else {
                throw PetStoreError.unsupportedSchema(state.schemaVersion)
            }
            return state
        } catch let error as PetStoreError {
            throw error
        } catch {
            throw PetStoreError.corruptState(stateURL.path, error)
        }
    }

    private func saveUnlocked(_ state: PetState) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: stateURL.path
            )
        } catch {
            throw PetStoreError.cannotWriteState(stateURL.path, error)
        }
    }
}
