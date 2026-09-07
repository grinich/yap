import AppKit
import SwiftUI

/// Sits above the camera renderer, below meeting controls. Gallery tiles keep
/// their own reorder gesture; this surface is used by the focused video layout.
struct WhooshVideoWindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> VideoWindowDragView { VideoWindowDragView() }
    func updateNSView(_ nsView: VideoWindowDragView, context: Context) {}
}

@MainActor
final class VideoWindowDragView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let secondary clicks reach the participant's existing context menu.
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
