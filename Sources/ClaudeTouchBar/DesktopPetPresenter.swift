import AppKit

/// Owns the always-on-top, draggable desktop pet window.
final class DesktopPetPresenter: NSObject, NSWindowDelegate {
    private static let defaultsSuite = "com.zhihu.claude-touchbar"
    private static let originXKey = "desktopPetOriginX"
    private static let originYKey = "desktopPetOriginY"
    private static let defaultMargin: CGFloat = 24

    private let petView = DesktopPetView()
    private let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
    private lazy var panel = makePanel()
    private var restoredPosition = false
    private var pendingBounces = 0
    private var bounceInProgress = false
    private(set) var isPresented = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(state: PetState, at now: Date) {
        petView.update(state: state, at: now)
    }

    func setActions(onFeed: @escaping () -> Void, onSleep: @escaping () -> Void) {
        petView.onFeed = onFeed
        petView.onSleep = onSleep
    }

    func present() {
        guard !isPresented else { return }
        restorePositionIfNeeded()
        panel.orderFrontRegardless()
        isPresented = true
    }

    func dismiss() {
        guard isPresented else { return }
        pendingBounces = 0
        bounceInProgress = false
        petView.cancelBounce()
        panel.orderOut(nil)
        isPresented = false
    }

    func enqueueBounces(_ count: Int) {
        guard isPresented, count > 0 else { return }
        pendingBounces += count
        playNextBounceIfNeeded()
    }

    func windowDidMove(_ notification: Notification) {
        guard restoredPosition else { return }
        defaults.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
        defaults.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard restoredPosition else { return }
        panel.setFrameOrigin(visibleOrigin(for: panel.frame))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DesktopPetView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.contentView = petView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func restorePositionIfNeeded() {
        guard !restoredPosition else { return }
        _ = panel
        let origin: NSPoint
        if defaults.object(forKey: Self.originXKey) != nil,
           defaults.object(forKey: Self.originYKey) != nil
        {
            origin = NSPoint(
                x: defaults.double(forKey: Self.originXKey),
                y: defaults.double(forKey: Self.originYKey)
            )
        } else {
            origin = defaultOrigin()
        }
        panel.setFrameOrigin(visibleOrigin(for: NSRect(origin: origin, size: panel.frame.size)))
        restoredPosition = true
    }

    private func defaultOrigin() -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(
            x: visible.maxX - panel.frame.width - Self.defaultMargin,
            y: visible.minY + Self.defaultMargin
        )
    }

    private func visibleOrigin(for frame: NSRect) -> NSPoint {
        let screen = NSScreen.screens.max { first, second in
            first.visibleFrame.intersection(frame).area < second.visibleFrame.intersection(frame).area
        }
        guard let visible = screen?.visibleFrame,
              visible.intersection(frame).area > 0
        else { return defaultOrigin() }

        let maximumX = max(visible.minX, visible.maxX - frame.width)
        let maximumY = max(visible.minY, visible.maxY - frame.height)
        return NSPoint(
            x: min(maximumX, max(visible.minX, frame.origin.x)),
            y: min(maximumY, max(visible.minY, frame.origin.y))
        )
    }

    private func playNextBounceIfNeeded() {
        guard isPresented, !bounceInProgress, pendingBounces > 0 else { return }
        pendingBounces -= 1
        bounceInProgress = true
        petView.bounce { [weak self] in
            guard let self else { return }
            self.bounceInProgress = false
            self.playNextBounceIfNeeded()
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}
