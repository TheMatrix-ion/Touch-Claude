import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Evaluation {
        let now: Date
        let running: Bool
        let mode: Mode
        let modeChangedAt: Date?
        let state: PetState?
        let bounceEvents: [URL]
        let errors: [Error]
    }

    private let presenter = TouchBarPresenter()
    private let store = PetStore()
    private let engine = PetEngine()
    private let stopQueue = StopEventQueue()
    private let workQueue = DispatchQueue(label: "com.zhihu.claude-touchbar.worker", qos: .utility)
    private let pollInterval: TimeInterval = 1.5
    private let checkpointInterval: TimeInterval = 60

    private var pollTimer: Timer?
    private var evaluationInFlight = false
    private var forceOfflineNextEvaluation = false
    private var systemSleeping = false

    // These are accessed only on workQueue (or while the main thread holds a
    // synchronous barrier on workQueue).
    private var lastCheckpointAt: Date?
    private var lastWallSample: Date?
    private var lastUptimeSample: TimeInterval?

    // Presentation is edge-triggered so brightness/volume and the system close
    // button are not stolen back on every poll.
    private var lastAppliedShow: Bool?
    private var lastModeChange: Date?
    private var nextPresentRetryAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // The gap since the last persisted checkpoint happened while the helper
        // was not running, so the pet was sleeping for that interval.
        evaluatePresence(forceOffline: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.evaluatePresence()
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        checkpointSynchronously(passage: systemSleeping ? .offline : .online)
        presenter.dismiss()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        checkpointSynchronously(passage: .online)
        systemSleeping = true
    }

    @objc private func systemDidWake(_ notification: Notification) {
        systemSleeping = false
        evaluatePresence(forceOffline: true)
    }

    private func checkpointSynchronously(passage: TimePassage) {
        let now = Date()
        workQueue.sync {
            do {
                _ = try store.advance(at: now, passage: passage)
                lastCheckpointAt = now
                lastWallSample = now
                lastUptimeSample = ProcessInfo.processInfo.systemUptime
            } catch {
                Log.debug("pet checkpoint failed: \(error)")
            }
        }
    }

    private func evaluatePresence(forceOffline: Bool = false) {
        if forceOffline { forceOfflineNextEvaluation = true }
        guard !evaluationInFlight else { return }

        let applyOfflinePassage = forceOfflineNextEvaluation
        forceOfflineNextEvaluation = false
        evaluationInFlight = true

        workQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            let inferredSleep = self.inferSystemSleep(now: now, uptime: uptime)
            var errors: [Error] = []

            let passage: TimePassage = (applyOfflinePassage || inferredSleep) ? .offline : .online
            if passage == .offline
                || self.lastCheckpointAt == nil
                || now.timeIntervalSince(self.lastCheckpointAt!) >= self.checkpointInterval
            {
                do {
                    _ = try self.store.advance(at: now, passage: passage)
                    self.lastCheckpointAt = now
                } catch {
                    errors.append(error)
                }
            }

            errors.append(contentsOf: self.stopQueue.processDue(at: now))

            var state: PetState?
            do {
                if var projected = try self.store.snapshot() {
                    self.engine.advance(&projected, to: now, passage: .online)
                    state = projected
                } else {
                    state = try self.store.advance(at: now, passage: passage)
                    self.lastCheckpointAt = now
                }
            } catch {
                errors.append(error)
            }

            let running = ClaudeProcessMonitor.isRunning()
            let mode = ModeSignal.read()
            let evaluation = Evaluation(
                now: now,
                running: running,
                mode: mode.mode,
                modeChangedAt: mode.changedAt,
                state: state,
                bounceEvents: PokeSignal.pending(),
                errors: errors
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.evaluationInFlight = false
                for error in evaluation.errors { Log.debug("pet refresh failed: \(error)") }
                // Token settlement happens on workQueue before this snapshot is
                // read. Refresh all three metrics before starting the two hops.
                if let state = evaluation.state {
                    self.presenter.update(state: state, at: evaluation.now)
                }
                self.applyPresence(
                    running: evaluation.running,
                    mode: evaluation.mode,
                    modeChangedAt: evaluation.modeChangedAt,
                    now: evaluation.now
                )
                self.handleBounceEvents(evaluation.bounceEvents)

                // A wake notification may arrive while a prior evaluation is
                // running. Do not lose its offline/sleep accounting request.
                if self.forceOfflineNextEvaluation { self.evaluatePresence() }
            }
        }
    }

    private func inferSystemSleep(now: Date, uptime: TimeInterval) -> Bool {
        defer {
            lastWallSample = now
            lastUptimeSample = uptime
        }
        guard let previousWall = lastWallSample, let previousUptime = lastUptimeSample else {
            return false
        }
        let wallDelta = now.timeIntervalSince(previousWall)
        let uptimeDelta = uptime - previousUptime
        return uptimeDelta < 0 || wallDelta - uptimeDelta > max(5, pollInterval * 2)
    }

    private func handleBounceEvents(_ urls: [URL]) {
        var consumed = 0
        for url in urls {
            do {
                try PokeSignal.consume(url)
                consumed += 1
            } catch {
                Log.debug("failed to consume bounce event: \(error)")
            }
        }
        presenter.enqueueBounces(consumed)
    }

    private func applyPresence(running: Bool, mode: Mode, modeChangedAt: Date?, now: Date) {
        var commandIssued = false
        if let modeChangedAt, modeChangedAt != lastModeChange {
            lastModeChange = modeChangedAt
            commandIssued = lastAppliedShow != nil
        }

        let shouldShow: Bool
        switch mode {
        case .wake: shouldShow = true
        case .sleep: shouldShow = false
        case .auto: shouldShow = running
        }

        guard commandIssued || shouldShow != lastAppliedShow else { return }
        if shouldShow {
            if !commandIssued, let retryAt = nextPresentRetryAt, now < retryAt { return }
            if presenter.present() {
                lastAppliedShow = true
                nextPresentRetryAt = nil
            } else {
                // Do not cache a failed private-selector call as success. Retry
                // at a low cadence while all CLI/game state remains functional.
                lastAppliedShow = nil
                nextPresentRetryAt = now.addingTimeInterval(10)
            }
        } else {
            presenter.dismiss()
            lastAppliedShow = false
            nextPresentRetryAt = nil
        }
    }
}
