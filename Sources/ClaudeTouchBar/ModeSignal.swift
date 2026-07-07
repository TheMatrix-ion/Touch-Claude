import Foundation

/// The user's manual show/hide preference for the mascot, written by the `clawd`
/// command and polled by the running helper.
///
/// - `.auto`  — follow Claude: show while the CLI runs, hide when it stops (default).
/// - `.wake`  — always show the mascot, regardless of whether Claude is running.
/// - `.sleep` — always hide the mascot.
enum Mode: String {
    case auto
    case wake
    case sleep
}

/// File-based IPC between the `clawd` command and the long-running helper,
/// mirroring how `PokeSignal` works. The helper watches the file's modification
/// date to notice a *freshly issued* command (so `clawd wake` can force the bar
/// back even when the helper's own view of it is stale).
enum ModeSignal {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-touchbar/mode").path

    /// The persisted mode plus the file's modification date (nil if never set).
    static func read() -> (mode: Mode, changedAt: Date?) {
        // Fresh stat each call, like PokeSignal — a cached URL would miss updates.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let changedAt = attributes?[.modificationDate] as? Date
        let raw = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = raw.flatMap(Mode.init(rawValue:)) ?? .auto
        return (mode, changedAt)
    }

    /// Persist the desired mode (called by the `clawd wake/sleep/auto` subcommands).
    static func write(_ mode: Mode) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try mode.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
