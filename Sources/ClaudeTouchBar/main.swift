import AppKit
import Foundation

// `--once` prints whether Claude CLI is currently detected, then exits.
// Useful for verifying the process trigger without needing a Touch Bar.
if CommandLine.arguments.contains("--once") {
    let running = ClaudeProcessMonitor.isRunning()
    print(running ? "claude CLI detected (Touch Bar would show)" : "no claude CLI process")
    exit(running ? EXIT_SUCCESS : EXIT_FAILURE)
}

// Any extra argument means "act as the `clawd` CLI, don't launch the helper".
// The already-running helper instance picks up the effect on its next poll.
//   clawd wake | sleep | auto  — set the manual show/hide mode
//   clawd jump                 — poke the mascot to hop (simulate Claude finishing)
let extraArguments = Array(CommandLine.arguments.dropFirst())
if let command = extraArguments.first {
    if command == "jump" {
        do {
            try PokeSignal.poke()
            print("clawd: jump — nudged the mascot")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("clawd: failed to jump: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    guard let mode = Mode(rawValue: command) else {
        FileHandle.standardError.write(Data("usage: clawd [wake|sleep|auto|jump]\n".utf8))
        exit(EXIT_FAILURE)
    }
    do {
        try ModeSignal.write(mode)
        switch mode {
        case .wake:  print("clawd: awake — the Claude mascot will show")
        case .sleep: print("clawd: asleep — the Claude mascot is hidden")
        case .auto:  print("clawd: auto — the mascot follows Claude")
        }
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("clawd: failed to set mode: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
