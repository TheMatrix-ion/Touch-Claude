import Foundation

/// The user's manual show/hide preference for the mascot, written by the `clawd`
/// command and polled by the running helper.
///
/// - `.auto`  — `clawd view auto`: follow the Claude process (default).
/// - `.wake`  — legacy on-disk value for `clawd view show`.
/// - `.sleep` — legacy on-disk value for `clawd view hide`.
enum Mode: String {
    case auto
    case wake
    case sleep
}

/// File-based IPC between the `clawd` command and the long-running helper,
/// mirroring how `PokeSignal` works. The helper watches the file's modification
/// date to notice a *freshly issued* command (so `clawd view show` can force
/// the bar back even when the helper's own view of it is stale).
enum ModeSignal {
    static var path: String { path(in: PetStore.defaultDirectory()).path }

    static func path(in directory: URL) -> URL {
        directory.appendingPathComponent("mode", isDirectory: false)
    }

    /// The persisted mode plus the file's modification date (nil if never set).
    static func read(in directory: URL = PetStore.defaultDirectory()) -> (mode: Mode, changedAt: Date?) {
        let path = path(in: directory).path
        // Fresh stat each call, like PokeSignal — a cached URL would miss updates.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let changedAt = attributes?[.modificationDate] as? Date
        let raw = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = raw.flatMap(Mode.init(rawValue:)) ?? .auto
        return (mode, changedAt)
    }

    /// Persist the desired mode (called by `clawd view show|hide|auto`).
    static func write(_ mode: Mode, in dataDirectory: URL = PetStore.defaultDirectory()) throws {
        let path = path(in: dataDirectory).path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try mode.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: path
        )
    }
}
