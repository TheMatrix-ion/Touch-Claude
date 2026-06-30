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

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.itemIdentifier]
    }

    /// Push the bar onto the Touch Bar. Safe to call repeatedly: re-asserting an
    /// already-visible bar is how we recover after the user taps the system "✕"
    /// close button (which removes our bar without notifying us).
    func present() {
        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
        ]
        guard performTouchBarClassSelector(selectors, first: touchBar, second: Self.trayIdentifier as NSString) else {
            return
        }
        isPresented = true
    }

    /// Play the mascot's "Claude finished" hop (no-op if not visible).
    func bounce() {
        guard isPresented else { return }
        logoView.bounce()
    }

    func dismiss() {
        guard isPresented else { return }

        let selectors = [
            "dismissSystemModalTouchBar:",
            "dismissSystemModalFunctionBar:",
        ]
        _ = performTouchBarClassSelector(selectors, first: touchBar, second: nil)
        isPresented = false
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
