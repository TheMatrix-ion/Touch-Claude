import Foundation

/// Lightweight stderr logger, enabled by setting CLAUDE_TB_DEBUG=1.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["CLAUDE_TB_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(("[claude-tb] " + message() + "\n").data(using: .utf8)!)
    }
}
