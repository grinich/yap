import AppKit
import Testing
@testable import WhooshAppUI

@MainActor @Suite struct VideoWindowDragTests {
    @Test func primaryDragMovesTheOwningWindowWithoutChangingItsConfiguration() throws {
        let window = DragTrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = VideoWindowDragView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = surface
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 150, y: 120),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        #expect(window.draggedEvents == [event.eventNumber])
        #expect(window.isMovable)
        #expect(surface.acceptsFirstMouse(for: event))
        #expect(!surface.isOpaque)
        #expect(!surface.isAccessibilityElement())
        window.isMovable = false // A menu or another native interaction owns tracking.
        surface.mouseDown(with: event)
        #expect(window.draggedEvents.count == 1)
    }

    @Test func secondaryClicksAndDetachedSurfacesCannotMoveAWindow() throws {
        let surface = VideoWindowDragView()
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        #expect(surface.window == nil)
    }
}

@MainActor private final class DragTrackingWindow: NSWindow {
    var draggedEvents: [Int] = []
    override func performDrag(with event: NSEvent) { draggedEvents.append(event.eventNumber) }
}
