import AppKit
import Testing
@testable import YapAppUI

@Suite("Window-wide pointer presence")
struct YapWindowPointerPresenceTests {
    private let frame = CGRect(x: 100, y: 100, width: 640, height: 540)

    @Test func initialPresenceIncludesTitlebarAndSuppressesDuplicateUpdates() {
        var state = YapWindowPointerState()
        let titlebarPoint = CGPoint(x: 130, y: 632)
        let initial = state.update(pointer: titlebarPoint, windowFrame: frame, isVisible: true)
        let duplicate = state.update(pointer: titlebarPoint, windowFrame: frame, isVisible: true)
        let videoPoint = state.update(pointer: CGPoint(x: 300, y: 350), windowFrame: frame, isVisible: true)
        #expect(initial == true)
        #expect(duplicate == nil)
        #expect(videoPoint == nil)
    }

    @Test func movingAndResizingWindowRecomputesPresenceWithoutPointerMotion() {
        var state = YapWindowPointerState()
        let pointer = CGPoint(x: 200, y: 300)
        let inside = state.update(pointer: pointer, windowFrame: frame, isVisible: true)
        let moved = state.update(pointer: pointer, windowFrame: frame.offsetBy(dx: 500, dy: 0), isVisible: true)
        let resized = state.update(pointer: pointer, windowFrame: frame, isVisible: true)
        #expect(inside == true)
        #expect(moved == false)
        #expect(resized == true)
    }

    @Test func hiddenMinimizedOtherSpaceAndDetachedWindowsReportOutside() {
        var state = YapWindowPointerState()
        let point = CGPoint(x: 200, y: 300)
        let hidden = state.update(pointer: point, windowFrame: frame, isVisible: false)
        let visible = state.update(pointer: point, windowFrame: frame, isVisible: true)
        let minimized = state.update(pointer: point, windowFrame: frame, isVisible: true, isMiniaturized: true)
        let restored = state.update(pointer: point, windowFrame: frame, isVisible: true)
        let otherSpace = state.update(pointer: point, windowFrame: frame, isVisible: true, isOnActiveSpace: false)
        let detached = state.update(pointer: point, windowFrame: nil, isVisible: true)
        #expect(hidden == false)
        #expect(visible == true)
        #expect(minimized == false)
        #expect(restored == true)
        #expect(otherSpace == false)
        #expect(detached == nil)
        #expect(state.isInside == false)
    }

    @Test func pointerExitAndReentryEmitOnlyActualChanges() {
        var state = YapWindowPointerState()
        let initialOutside = state.update(pointer: .zero, windowFrame: frame, isVisible: true)
        let entry = state.update(pointer: CGPoint(x: 110, y: 110), windowFrame: frame, isVisible: true)
        let exit = state.update(pointer: CGPoint(x: 750, y: 300), windowFrame: frame, isVisible: true)
        let stillOutside = state.update(pointer: CGPoint(x: 760, y: 320), windowFrame: frame, isVisible: true)
        let reentry = state.update(pointer: CGPoint(x: 700, y: 500), windowFrame: frame, isVisible: true)
        #expect(initialOutside == false)
        #expect(entry == true)
        #expect(exit == false)
        #expect(stillOutside == nil)
        #expect(reentry == true)
    }

    @Test func coveredOrDeactivatedWindowDoesNotClaimPointerFromBoundsAlone() {
        var state = YapWindowPointerState()
        let point = CGPoint(x: 200, y: 300)
        let visible = state.update(pointer: point, windowFrame: frame, isVisible: true)
        let covered = state.update(pointer: point, windowFrame: frame, isVisible: true, isOccluded: true)
        let revealedWithoutPointerEvent = state.update(pointer: point, windowFrame: frame, isVisible: true,
                                                        isPointerLocationKnown: false)
        let actualPointerEvent = state.update(pointer: point, windowFrame: frame, isVisible: true)
        let deactivated = state.update(pointer: point, windowFrame: frame, isVisible: true,
                                       isPointerLocationKnown: false)
        #expect(visible == true)
        #expect(covered == false)
        #expect(revealedWithoutPointerEvent == nil)
        #expect(actualPointerEvent == true)
        #expect(deactivated == false)
    }
}

@Suite("Native window pointer input", .serialized) @MainActor
struct YapNativeWindowPointerTests {
    @Test func deliveredPointerOverridesStaleOcclusionUntilPassiveVisibilityChanges() throws {
        _ = NSApplication.shared
        let window = PointerFixtureWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 640, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.reportsVisibleOcclusion = false
        let view = YapWindowPointerTrackingView()
        let content = try #require(window.contentView)
        view.frame = content.bounds
        content.addSubview(view)
        defer { view.stop(); view.removeFromSuperview(); window.close() }
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: CGPoint(x: 320, y: 220), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        #expect(event.window === window)
        #expect(!window.occlusionState.contains(.visible))
        #expect(!view.isPointerInside)

        view.mouseMoved(with: event)
        #expect(view.isPointerInside)
        view.refreshAttachment()
        #expect(view.isPointerInside)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!view.isPointerInside)

        view.mouseEntered(with: event)
        #expect(view.isPointerInside)
        view.mouseExited(with: event)
        #expect(!view.isPointerInside)
    }

    @Test func deliveredEventPositionSurvivesSwiftUIRefreshWithoutPhysicalCursorMotion() throws {
        _ = NSApplication.shared
        let physicalPointer = NSEvent.mouseLocation
        let window = PointerFixtureWindow(contentRect: CGRect(x: physicalPointer.x + 10_000,
            y: physicalPointer.y + 10_000, width: 640, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = YapWindowPointerTrackingView()
        let content = try #require(window.contentView)
        view.frame = content.bounds
        content.addSubview(view)
        defer { view.stop(); view.removeFromSuperview(); window.close() }
        #expect(!window.frame.contains(NSEvent.mouseLocation))
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: CGPoint(x: 320, y: 220), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        #expect(event.window === window)

        view.mouseMoved(with: event)
        #expect(view.isPointerInside)
        view.refreshAttachment()
        view.refreshAttachment()
        #expect(view.isPointerInside)

        view.mouseExited(with: event)
        #expect(!view.isPointerInside)
        view.mouseEntered(with: event)
        #expect(view.isPointerInside)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!view.isPointerInside)
    }
}

/// Supplies visibility metadata without ever ordering a test window onscreen.
@MainActor
private final class PointerFixtureWindow: NSWindow {
    var reportsVisibleOcclusion = true
    override var isVisible: Bool { true }
    override var isOnActiveSpace: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { reportsVisibleOcclusion ? [.visible] : [] }
}
