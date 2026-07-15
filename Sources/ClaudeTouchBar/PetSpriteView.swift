import AppKit

/// Draws the shared pixel-art pet with nearest-neighbour scaling and one quick
/// two-hop completion animation. The timer-driven redraw also works inside the
/// remotely rendered Touch Bar.
final class PetSpriteView: NSView {
    private var image: NSImage
    private let bounceAmplitude: CGFloat
    private let renderedSize: NSSize?

    private var bounceOffset: CGFloat = 0
    private var bounceTimer: Timer?
    private var bounceStart: Date?
    private let hopsPerRound: Double = 2
    private let roundActiveDuration: TimeInterval = 0.55
    private let roundPauseDuration: TimeInterval = 0.22
    private var completion: (() -> Void)?

    private var bounceTotalDuration: TimeInterval {
        roundActiveDuration + roundPauseDuration
    }

    init(image: NSImage, bounceAmplitude: CGFloat, renderedSize: NSSize? = nil) {
        self.image = image
        self.bounceAmplitude = bounceAmplitude
        self.renderedSize = renderedSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bounce(completion: @escaping () -> Void) {
        if bounceTimer != nil { stopBounce(invokeCompletion: false) }
        self.completion = completion
        bounceStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickBounce()
        }
        RunLoop.main.add(timer, forMode: .common)
        bounceTimer = timer
    }

    func cancelBounce() {
        stopBounce(invokeCompletion: false)
    }

    func update(image: NSImage) {
        guard self.image !== image else { return }
        self.image = image
        needsDisplay = true
        displayIfNeeded()
    }

    private func tickBounce() {
        guard let start = bounceStart else {
            stopBounce(invokeCompletion: true)
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < bounceTotalDuration else {
            stopBounce(invokeCompletion: true)
            return
        }

        if elapsed < roundActiveDuration {
            let progress = elapsed / roundActiveDuration
            bounceOffset = bounceAmplitude * CGFloat(abs(sin(.pi * hopsPerRound * progress)))
        } else {
            bounceOffset = 0
        }
        needsDisplay = true
    }

    private func stopBounce(invokeCompletion: Bool) {
        let finished = completion
        completion = nil
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceStart = nil
        bounceOffset = 0
        needsDisplay = true
        if invokeCompletion { finished?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .none
        let size = renderedSize ?? bounds.size
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.minY + bounceOffset,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
