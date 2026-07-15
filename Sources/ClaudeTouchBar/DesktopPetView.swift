import AppKit

/// Transparent desktop presentation of the same pet state shown in the Touch Bar.
final class DesktopPetView: NSView {
    static let preferredSize = NSSize(width: 220, height: 166)

    private let sprite = PetSpriteView(
        image: ClaudePixelImage.image,
        bounceAmplitude: 14,
        renderedSize: NSSize(width: 136, height: 118)
    )
    private let statusLabel: NSTextField = {
        let field = NSTextField(labelWithString: "♥100  🍖80  ⚡100")
        field.cell = VerticallyCenteredTextFieldCell(textCell: field.stringValue)
        return field
    }()
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartWindowOrigin
        else { return }
        let currentMouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: startOrigin.x + currentMouse.x - startMouse.x,
            y: startOrigin.y + currentMouse.y - startMouse.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    func update(state: PetState, at now: Date) {
        let condition = PetCondition.derive(from: state, at: now)
        sprite.update(image: ClaudePetImages.image(for: condition.expression))
        statusLabel.stringValue = PetCondition.touchBarText(from: state, at: now)
        switch condition {
        case .healthy: statusLabel.textColor = .white
        case .hungry, .tired: statusLabel.textColor = .systemYellow
        case .critical: statusLabel.textColor = .systemOrange
        case .sleeping: statusLabel.textColor = .systemBlue
        case .starving, .dead: statusLabel.textColor = .systemRed
        }
    }

    func bounce(completion: @escaping () -> Void) {
        sprite.bounce(completion: completion)
    }

    func cancelBounce() {
        sprite.cancelBounce()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        sprite.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.wantsLayer = true
        statusLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        statusLabel.layer?.cornerRadius = 11
        statusLabel.layer?.masksToBounds = true

        addSubview(sprite)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            sprite.topAnchor.constraint(equalTo: topAnchor),
            sprite.centerXAnchor.constraint(equalTo: centerXAnchor),
            sprite.widthAnchor.constraint(equalToConstant: 136),
            sprite.heightAnchor.constraint(equalToConstant: 132),
            statusLabel.topAnchor.constraint(equalTo: sprite.bottomAnchor, constant: 2),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 196),
            statusLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        let verticalInset = max(0, floor((rect.height - textHeight) / 2) - 1)
        let centered = NSRect(
            x: rect.minX,
            y: rect.minY + verticalInset,
            width: rect.width,
            height: textHeight
        )
        return super.drawingRect(forBounds: centered)
    }
}
