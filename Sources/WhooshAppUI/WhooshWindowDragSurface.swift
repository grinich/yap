import AppKit
import SwiftUI

/// Overlay a padded header so passive title text also moves the window.
/// Interactive controls retain tracking through WhooshWindowInteractionRegion.
struct WhooshWindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> WhooshWindowDragView { WhooshWindowDragView() }
    func updateNSView(_ nsView: WhooshWindowDragView, context: Context) {}
}

@MainActor
class WhooshWindowDragView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A control's local event monitor suspends dragging before AppKit routes
        // the press. Let it receive the event beneath the native drag overlay.
        guard window?.isMovable != false else { return nil }
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
              let window, window.isMovable, !window.styleMask.contains(.fullScreen) else { return }
        window.performDrag(with: event)
    }
}
