import AppKit

/// Pushes (and removes) a custom view onto the system Touch Bar using the private
/// `presentSystemModalTouchBar` / `dismissSystemModalTouchBar` class selectors.
/// This is the same mechanism Touch Bar quota widgets use; it works from an
/// `.accessory` app with no Dock icon.
final class TouchBarPresenter: NSObject, NSTouchBarDelegate {
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.zhihu.claude-touchbar.logo")
    private static let trayIdentifier = "com.zhihu.claude-touchbar"

    private let touchBar = NSTouchBar()
    private let logoView = ClaudeLogoView()
    private(set) var isPresented = false
    private var pendingBounces = 0
    private var bounceInProgress = false

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.itemIdentifier]
    }

    /// Push the bar onto the Touch Bar. Called once on the running edge (see
    /// `AppDelegate.applyPresence`) — we deliberately do *not* re-assert it every
    /// poll, because a system modal Touch Bar steals the bar back and would break
    /// the user's taps on brightness/volume and the system "✕" close button.
    /// Presenting with a system tray item lets the user re-summon it themselves.
    @discardableResult
    func present() -> Bool {
        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
        ]
        guard performTouchBarClassSelector(selectors, first: touchBar, second: Self.trayIdentifier as NSString) else {
            return false
        }
        isPresented = true
        return true
    }

    func update(state: PetState, at now: Date) {
        logoView.update(state: state, at: now)
    }

    /// Queue one two-hop animation per completed player prompt. Events are
    /// serialized instead of restarting an in-flight animation.
    func enqueueBounces(_ count: Int) {
        guard isPresented, count > 0 else { return }
        pendingBounces += count
        playNextBounceIfNeeded()
    }

    func dismiss() {
        pendingBounces = 0
        bounceInProgress = false
        logoView.cancelBounce()
        guard isPresented else { return }

        let selectors = [
            "dismissSystemModalTouchBar:",
            "dismissSystemModalFunctionBar:",
        ]
        _ = performTouchBarClassSelector(selectors, first: touchBar, second: nil)
        isPresented = false
    }

    private func playNextBounceIfNeeded() {
        guard isPresented, !bounceInProgress, pendingBounces > 0 else { return }
        pendingBounces -= 1
        bounceInProgress = true
        logoView.bounce { [weak self] in
            guard let self else { return }
            self.bounceInProgress = false
            self.playNextBounceIfNeeded()
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else {
            return nil
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = logoView
        return item
    }

    private func performTouchBarClassSelector(_ selectorNames: [String], first: Any, second: Any?) -> Bool {
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            let target = NSTouchBar.self as AnyObject
            guard target.responds(to: selector) else {
                continue
            }

            if let second {
                _ = target.perform(selector, with: first, with: second)
            } else {
                _ = target.perform(selector, with: first)
            }
            return true
        }
        return false
    }
}
