import AppKit

/// Transparent desktop presentation of the same pet state shown in the Touch Bar.
final class DesktopPetView: NSView {
    static let preferredSize = NSSize(width: 190, height: 142)

    private let sprite = PetSpriteView(
        image: ClaudePixelImage.image,
        bounceAmplitude: 12,
        renderedSize: NSSize(width: 116, height: 100)
    )
    private let statusContainer = NSView()
    private let healthMetric = StatusMetricView(icon: "♥", value: "100")
    private let hungerMetric = StatusMetricView(icon: "🍖", value: "80")
    private let staminaMetric = StatusMetricView(icon: "⚡", value: "100")
    private let sleepingLabel = NSTextField(labelWithString: "sleeping")
    private lazy var metricsStack = NSStackView(
        views: [healthMetric, hungerMetric, staminaMetric]
    )
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
        let textColor: NSColor
        switch condition {
        case .healthy: textColor = .white
        case .hungry, .tired: textColor = .systemYellow
        case .critical: textColor = .systemOrange
        case .sleeping: textColor = .systemBlue
        case .starving, .dead: textColor = .systemRed
        }

        let isSleeping = condition == .sleeping
        metricsStack.isHidden = isSleeping
        sleepingLabel.isHidden = !isSleeping
        sleepingLabel.textColor = textColor
        guard !isSleeping else { return }

        healthMetric.update(value: Int(state.health.rounded()), color: textColor)
        hungerMetric.update(
            value: Int(PetPresentation.hungerLevel(fromDebt: state.hunger).rounded()),
            color: textColor
        )
        staminaMetric.update(value: Int(state.stamina.rounded()), color: textColor)
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

        statusContainer.wantsLayer = true
        statusContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        statusContainer.layer?.cornerRadius = 10
        statusContainer.layer?.masksToBounds = true
        statusContainer.translatesAutoresizingMaskIntoConstraints = false

        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 0
        metricsStack.translatesAutoresizingMaskIntoConstraints = false

        sleepingLabel.cell = VerticallyCenteredTextFieldCell(textCell: sleepingLabel.stringValue)
        sleepingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sleepingLabel.alignment = .center
        sleepingLabel.textColor = .systemBlue
        sleepingLabel.isHidden = true
        sleepingLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sprite)
        addSubview(statusContainer)
        statusContainer.addSubview(metricsStack)
        statusContainer.addSubview(sleepingLabel)
        NSLayoutConstraint.activate([
            sprite.topAnchor.constraint(equalTo: topAnchor),
            sprite.centerXAnchor.constraint(equalTo: centerXAnchor),
            sprite.widthAnchor.constraint(equalToConstant: 116),
            sprite.heightAnchor.constraint(equalToConstant: 112),
            statusContainer.topAnchor.constraint(equalTo: sprite.bottomAnchor, constant: 2),
            statusContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusContainer.widthAnchor.constraint(equalToConstant: 166),
            statusContainer.heightAnchor.constraint(equalToConstant: 22),
            metricsStack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 6),
            metricsStack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -6),
            metricsStack.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 3),
            metricsStack.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -3),
            healthMetric.widthAnchor.constraint(equalTo: hungerMetric.widthAnchor),
            hungerMetric.widthAnchor.constraint(equalTo: staminaMetric.widthAnchor),
            sleepingLabel.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            sleepingLabel.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            sleepingLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
}

private final class StatusMetricView: NSView {
    private let iconLabel: NSTextField
    private let valueLabel: NSTextField

    init(icon: String, value: String) {
        iconLabel = NSTextField(labelWithString: icon)
        valueLabel = NSTextField(labelWithString: value)
        super.init(frame: .zero)

        iconLabel.cell = VerticallyCenteredTextFieldCell(textCell: icon)
        iconLabel.font = .systemFont(ofSize: 11)
        iconLabel.alignment = .center
        iconLabel.textColor = .white

        valueLabel.cell = VerticallyCenteredTextFieldCell(textCell: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .center

        let contentStack = NSStackView(views: [iconLabel, valueLabel])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 1
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            iconLabel.widthAnchor.constraint(equalToConstant: 15),
            iconLabel.heightAnchor.constraint(equalToConstant: 16),
            valueLabel.widthAnchor.constraint(equalToConstant: 29),
            valueLabel.heightAnchor.constraint(equalToConstant: 16),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: Int, color: NSColor) {
        valueLabel.stringValue = String(value)
        iconLabel.textColor = color
        valueLabel.textColor = color
    }
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        return NSRect(
            x: rect.minX,
            y: rect.midY - textHeight / 2,
            width: rect.width,
            height: textHeight
        )
    }
}
