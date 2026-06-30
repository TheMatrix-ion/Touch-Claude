import Foundation

/// Detects whether Claude Code is running in a terminal (the CLI), as opposed to
/// the Claude.app desktop build.
///
/// We match on the exact process name via `pgrep -x claude` (case-sensitive):
/// - The CLI process / its shim report comm `claude` (lowercase) → matched.
/// - Claude.app desktop reports `Claude` / `Electron …` → not matched.
/// - cmux and other helpers only mention "claude" inside their full argv, so an
///   exact-name match (not `pgrep -f`) avoids those false positives.
enum ClaudeProcessMonitor {
    static func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "claude"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        // Exclude our own pid defensively (our binary is "ClaudeTouchBar", so it
        // never matches `-x claude`, but this keeps the check robust).
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = text
            .split(whereSeparator: { $0 == "\n" })
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        return pids.contains { $0 != ownPID }
    }
}
