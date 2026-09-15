import AppKit
import Observation

/// A traffic-light-sized toggle with a full 24-point click target.
@MainActor
final class YapWindowPinButton: NSButton {
    private let windowLevel: YapWindowLevel
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    init(frame: NSRect, windowLevel: YapWindowLevel = .shared) {
        self.windowLevel = windowLevel
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        toolTip = "Keep on Top"
        setAccessibilityLabel("Keep on Top")
        target = self
        action = #selector(togglePin)
        observeState()
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func observeState() {
        withObservationTracking {
            refreshState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeState() }
        }
    }

    private func refreshState() {
        state = windowLevel.isEnabled ? .on : .off
        setAccessibilityValue(state == .on ? 1 : 0)
        needsDisplay = true
    }

    @objc private func togglePin() {
        windowLevel.isEnabled.toggle()
        refreshState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pinned = state == .on
        let circle = NSRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13)
        let fill = pinned ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        fill.withAlphaComponent(pinned ? 1 : isHighlighted ? 0.8 : isHovered ? 0.65 : 0.38).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let foreground = pinned ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.8)
        let symbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [foreground]))
        symbol?.draw(in: NSRect(x: bounds.midX - 4.5, y: bounds.midY - 4.5, width: 9, height: 9))
    }
}
