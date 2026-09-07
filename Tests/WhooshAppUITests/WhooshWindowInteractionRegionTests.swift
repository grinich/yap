import AppKit
import Testing
@testable import WhooshAppUI

@Suite("Interactive titlebar regions", .serialized) @MainActor
struct WhooshWindowInteractionRegionTests {
    @Test func onlyAnInsidePressSuspendsDraggingAndMouseUpRestoresIt() throws {
        try withRegion { window, region in
            region.handleLocalEvent(try event(.leftMouseDown, in: window, point: CGPoint(x: 200, y: 100)))
            #expect(window.isMovable)
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            #expect(!window.isMovable)
            region.handleLocalEvent(try event(.leftMouseUp, in: window, point: CGPoint(x: 200, y: 100)))
            #expect(window.isMovable)
        }
    }

    @Test func nativeMenuCompletionAndDetachRestoreOriginalState() throws {
        try withRegion { window, region in
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            #expect(!window.isMovable)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
            #expect(window.isMovable)
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            region.detach()
            #expect(window.isMovable)

            region.refreshAttachment()
            window.isMovable = false
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            region.handleLocalEvent(try event(.leftMouseUp, in: window))
            #expect(!window.isMovable)
        }
    }

    @Test func disabledAndHiddenControlsDoNotClaimWindowDragging() throws {
        try withRegion { window, region in
            region.isEnabled = false
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            #expect(window.isMovable)
            region.isEnabled = true
            region.isHidden = true
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            #expect(window.isMovable)
            region.isHidden = false
            region.handleLocalEvent(try event(.leftMouseDown, in: window))
            #expect(!window.isMovable)
            region.isEnabled = false
            #expect(window.isMovable)
        }
    }

    private func withRegion(_ body: (NSWindow, WhooshWindowInteractionTrackingView) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovable = true
        let region = WhooshWindowInteractionTrackingView(frame: CGRect(x: 20, y: 20, width: 32, height: 32))
        try #require(window.contentView).addSubview(region)
        defer { region.detach(); region.removeFromSuperview(); window.close() }
        try body(window, region)
    }

    private func event(_ type: NSEvent.EventType, in window: NSWindow,
                       point: CGPoint = CGPoint(x: 30, y: 30)) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
}
