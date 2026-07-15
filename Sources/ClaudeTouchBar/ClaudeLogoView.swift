import AppKit

/// The content shown on the Touch Bar: the pixel-art Claude mascot plus health,
/// hunger, and stamina.
final class ClaudeLogoView: NSView {
    private let mascot = PixelImageView(image: ClaudePixelImage.image)
    private let statusLabel = NSTextField(labelWithString: "♥100  🍖20  ⚡100")

    // Render the mascot at the natural aspect ratio of the source sprite.
    private let mascotHeight: CGFloat = 27

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 30))
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Play the "Claude finished" hop.
    func bounce(completion: @escaping () -> Void) {
        mascot.bounce(completion: completion)
    }

    func cancelBounce() {
        mascot.cancelBounce()
    }

    func update(state: PetState, at now: Date) {
        let condition = PetCondition.derive(from: state, at: now)
        mascot.update(image: ClaudePetImages.image(for: condition.expression))
        statusLabel.stringValue = PetCondition.touchBarText(from: state, at: now)
        switch condition {
        case .healthy: statusLabel.textColor = .white
        case .hungry, .tired: statusLabel.textColor = .systemYellow
        case .critical: statusLabel.textColor = .systemOrange
        case .sleeping: statusLabel.textColor = .systemBlue
        case .starving, .dead: statusLabel.textColor = .systemRed
        }
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        mascot.translatesAutoresizingMaskIntoConstraints = false

        let imageSize = ClaudePixelImage.image.size
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        let mascotWidth = (mascotHeight * aspect).rounded()

        let stack = NSStackView(views: [mascot, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            mascot.heightAnchor.constraint(equalToConstant: mascotHeight),
            mascot.widthAnchor.constraint(equalToConstant: mascotWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// Draws an image with nearest-neighbour scaling so pixel art stays crisp, and
/// can play a short two-hop bounce by offsetting the drawn image vertically.
/// The animation is driven by a timer + manual redraws (rather than Core
/// Animation) so it works reliably inside the remotely-rendered Touch Bar.
private final class PixelImageView: NSView {
    private var image: NSImage

    private var bounceOffset: CGFloat = 0
    private var bounceTimer: Timer?
    private var bounceStart: Date?
    // One completed prompt is exactly one quick double-hop.
    private let bounceAmplitude: CGFloat = 5
    private let hopsPerRound: Double = 2
    private let rounds: Int = 1
    private let roundActiveDuration: TimeInterval = 0.55
    private let roundPauseDuration: TimeInterval = 0.22

    private var roundTotalDuration: TimeInterval { roundActiveDuration + roundPauseDuration }
    private var bounceTotalDuration: TimeInterval { roundTotalDuration * Double(rounds) }
    private var completion: (() -> Void)?

    init(image: NSImage) {
        self.image = image
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
        // Touch Bar content is rendered out of process, so flush passive image
        // changes immediately instead of waiting for another animation frame.
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

        // Within each round, hop for `roundActiveDuration`, then hold still for
        // `roundPauseDuration` before the next round.
        let timeInRound = elapsed.truncatingRemainder(dividingBy: roundTotalDuration)
        if timeInRound < roundActiveDuration {
            let progress = timeInRound / roundActiveDuration
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
        let rect = NSRect(
            x: bounds.minX,
            y: bounds.minY + bounceOffset,
            width: bounds.width,
            height: bounds.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
