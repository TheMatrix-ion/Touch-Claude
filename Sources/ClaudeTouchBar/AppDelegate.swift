import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let presenter = TouchBarPresenter()
    private let pollInterval: TimeInterval = 1.5

    private var pollTimer: Timer?
    // Only bounce for pokes newer than launch, so a stale poke file never fires
    // a spurious hop on startup.
    private var pokeThreshold = Date()

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
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyPresence(running)
                self.handlePoke(pokeDate, running: running)
            }
        }
    }

    private func handlePoke(_ pokeDate: Date?, running: Bool) {
        Log.debug("poll: running=\(running) poke=\(pokeDate.map { "\($0.timeIntervalSince1970)" } ?? "nil") threshold=\(pokeThreshold.timeIntervalSince1970) presented=\(presenter.isPresented)")
        guard let pokeDate, pokeDate > pokeThreshold else { return }
        pokeThreshold = pokeDate
        Log.debug("poke ADVANCED -> bounce (running=\(running), presented=\(presenter.isPresented))")
        if running {
            presenter.bounce()
        }
    }

    private func applyPresence(_ running: Bool) {
        if running {
            // Re-assert every poll so a stray tap on the system "✕" close button
            // brings the mark back within one poll interval.
            presenter.present()
        } else if presenter.isPresented {
            presenter.dismiss()
        }
    }
}
