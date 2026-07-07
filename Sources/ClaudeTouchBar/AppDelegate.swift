import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let presenter = TouchBarPresenter()
    private let pollInterval: TimeInterval = 1.5

    private var pollTimer: Timer?
    // Only bounce for pokes newer than launch, so a stale poke file never fires
    // a spurious hop on startup.
    private var pokeThreshold = Date()
    // The last visibility we actually applied. We act only on *changes*, so the
    // modal bar is never re-asserted every poll — re-asserting is what stole the
    // Touch Bar from brightness/volume and defeated the "✕" close button.
    // nil = nothing applied yet (first poll).
    private var lastAppliedShow: Bool?
    // Modification date of the mode file the last time we saw it, used to detect
    // a freshly issued `clawd wake/sleep/auto` command.
    private var lastModeChange: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar — a silent background helper.
        NSApp.setActivationPolicy(.accessory)

        // Detect on a background queue so spawning pgrep never stutters the UI.
        evaluatePresence()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.evaluatePresence()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        presenter.dismiss()
    }

    private func evaluatePresence() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let running = ClaudeProcessMonitor.isRunning()
            let pokeDate = PokeSignal.lastModified()
            let mode = ModeSignal.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyPresence(running: running, mode: mode.mode, modeChangedAt: mode.changedAt)
                self.handlePoke(pokeDate, running: running)
            }
        }
    }

    private func handlePoke(_ pokeDate: Date?, running: Bool) {
        Log.debug("poll: running=\(running) poke=\(pokeDate.map { "\($0.timeIntervalSince1970)" } ?? "nil") threshold=\(pokeThreshold.timeIntervalSince1970) presented=\(presenter.isPresented)")
        guard let pokeDate, pokeDate > pokeThreshold else { return }
        pokeThreshold = pokeDate
        Log.debug("poke ADVANCED -> bounce (running=\(running), presented=\(presenter.isPresented))")
        // Hop whenever the mascot is on screen. `bounce()` no-ops when hidden, so
        // this covers both the real Stop-hook poke (Claude still running) and a
        // `clawd jump` test while the bar is force-shown via `clawd wake`.
        presenter.bounce()
    }

    private func applyPresence(running: Bool, mode: Mode, modeChangedAt: Date?) {
        // Did the user just run `clawd wake/sleep/auto`? A freshly-touched mode
        // file forces a re-apply, so `clawd wake` brings the mascot back even if
        // we lost track of it (e.g. the user minimized it with the system "✕",
        // which removes our bar without telling us).
        var commandIssued = false
        if let modeChangedAt, modeChangedAt != lastModeChange {
            lastModeChange = modeChangedAt
            // On the very first poll there's nothing to "recover", so a pre-existing
            // mode file is applied through the normal change path below, not forced.
            commandIssued = lastAppliedShow != nil
        }

        let shouldShow: Bool
        switch mode {
        case .wake:  shouldShow = true      // always show
        case .sleep: shouldShow = false     // always hide
        case .auto:  shouldShow = running   // follow Claude
        }

        // Act only on a change (or a fresh command). This is the whole fix: we
        // never re-assert the modal bar every poll, so taps on brightness/volume
        // and the system "✕" are no longer stolen back.
        guard commandIssued || shouldShow != lastAppliedShow else { return }
        lastAppliedShow = shouldShow
        if shouldShow {
            presenter.present()
        } else {
            presenter.dismiss()
        }
    }
}
