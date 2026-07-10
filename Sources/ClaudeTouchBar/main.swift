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
// Work/bounce events are deliberately available only to Claude Code's private
// `_record-stop` hook command; players cannot trigger them manually.
let extraArguments = Array(CommandLine.arguments.dropFirst())
if !extraArguments.isEmpty {
    exit(PetCLI().run(arguments: extraArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
