import AppKit

/// Keeps AppKit's button tracking and accessibility with a quiet, single-dot
/// appearance. Its action hides the main window or asks to leave an active call.
@MainActor
final class WhooshWindowCloseButton: NSButton {
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = "Close window"
        setAccessibilityLabel("Close window")
        setAccessibilitySubrole(.closeButton)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 13
        let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        NSColor.secondaryLabelColor.withAlphaComponent(isHighlighted ? 0.8 : isHovered ? 0.65 : 0.38).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if isHovered || window?.firstResponder === self {
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.2
            mark.lineCapStyle = .round
            for direction: CGFloat in [-1, 1] {
                mark.move(to: NSPoint(x: circle.midX - 2.3, y: circle.midY - direction * 2.3))
                mark.line(to: NSPoint(x: circle.midX + 2.3, y: circle.midY + direction * 2.3))
            }
            mark.stroke()
        }
    }
}
