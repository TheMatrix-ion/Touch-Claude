import AppKit

/// The content shown on the Touch Bar: the pixel-art Claude mascot plus health,
/// hunger, and stamina.
final class ClaudeLogoView: NSView {
    private let mascot = PetSpriteView(image: ClaudePixelImage.image, bounceAmplitude: 5)
    private let statusLabel = NSTextField(labelWithString: "♥100  🍖80  ⚡100")

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
