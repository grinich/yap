import AppKit
import Testing
@testable import YapAppUI

@Suite("Passive chat row hover", .serialized) @MainActor
struct YapHoverRegionTests {
    @Test func nativeTextAndToolbarRemainInteractiveWithoutSplittingTheHoverRegion() async throws {
        try await withRegion { window, _, row, region in
            let text = NSTextView(frame: CGRect(x: 8, y: 8, width: 230, height: 72))
            text.string = "A native, selectable message"
            row.addSubview(text)
            let toolbar = NSButton(title: "Reply", target: nil, action: nil)
            toolbar.frame = CGRect(x: 250, y: 60, width: 72, height: 28)
            row.addSubview(toolbar)
            var updates: [Bool] = []
            region.onChange = { updates.append($0) }
            let textPoint = CGPoint(x: 70, y: 40), toolbarPoint = CGPoint(x: 275, y: 74)
            #expect(region.hitTest(textPoint) == nil)
            #expect(try #require(window.contentView).hitTest(row.convert(toolbarPoint, to: window.contentView)) === toolbar)
            region.mouseEntered(with: try event(.mouseMoved, at: textPoint, in: region, window: window))
            await flush()
            #expect(updates == [true])
            region.mouseExited(with: try event(.mouseMoved, at: toolbarPoint, in: region, window: window))
            region.handleLocalEvent(try event(.leftMouseDown, at: toolbarPoint, in: region, window: window))
            region.handleLocalEvent(try event(.leftMouseDragged, at: toolbarPoint, in: region, window: window))
            region.refreshAttachment()
            await flush()
            #expect(region.isPointerInside)
            #expect(updates == [true])
            region.mouseExited(with: try event(.mouseMoved, at: CGPoint(x: -5, y: 40), in: region, window: window))
            await flush()
            #expect(updates == [true, false])
        }
    }

    @Test func clippingAndStationaryPointerRowMovementUseTheDeliveredPosition() async throws {
        try await withRegion { window, scroll, row, region in
            var updates: [Bool] = []
            region.onChange = { updates.append($0) }
            region.handleLocalEvent(try event(.mouseMoved, at: CGPoint(x: 100, y: 40), in: region, window: window))
            await flush()
            #expect(updates == [true])
            let origin = row.frame.origin
            row.setFrameOrigin(CGPoint(x: origin.x, y: origin.y + 200))
            await flush()
            #expect(updates == [true, false])
            row.setFrameOrigin(origin)
            await flush()
            #expect(updates == [true, false, true])

            scroll.contentView.scroll(to: CGPoint(x: 0, y: 140))
            scroll.reflectScrolledClipView(scroll.contentView)
            await flush()
            #expect(!region.isPointerInside)
            let clipped = region.visibleRect.intersection(region.bounds)
            #expect(clipped.height > 0 && clipped.height < region.bounds.height)
            let visiblePoint = CGPoint(x: clipped.midX, y: clipped.midY)
            let clippedPoint = CGPoint(x: clipped.midX,
                                      y: clipped.minY > region.bounds.minY ? region.bounds.minY + 1 : region.bounds.maxY - 1)
            region.handleLocalEvent(try event(.leftMouseDown, at: clippedPoint, in: region, window: window))
            #expect(!region.isPointerInside)
            region.handleLocalEvent(try event(.leftMouseDown, at: visiblePoint, in: region, window: window))
            await flush()
            #expect(region.isPointerInside)
        }
    }

    @Test func rapidTransitionsDeliverOnlyTheFinalChangedState() async throws {
        try await withRegion { window, _, _, region in
            var updates: [Bool] = []
            region.onChange = { updates.append($0) }
            let inside = try event(.mouseMoved, at: CGPoint(x: 120, y: 50), in: region, window: window)
            let outside = try event(.mouseMoved, at: CGPoint(x: -30, y: 50), in: region, window: window)
            region.handleLocalEvent(inside)
            region.handleLocalEvent(outside)
            await flush()
            #expect(updates.isEmpty)
            region.handleLocalEvent(inside)
            await flush()
            region.handleLocalEvent(outside)
            region.handleLocalEvent(inside)
            await flush()
            #expect(updates == [true])
            region.handleLocalEvent(outside)
            await flush()
            #expect(updates == [true, false])
        }
    }

    @Test func detachAndStopCancelOutdatedCallbacksAndRemoveTracking() async throws {
        try await withRegion { window, _, row, region in
            var updates: [Bool] = []
            region.onChange = { updates.append($0) }
            let inside = try event(.mouseMoved, at: CGPoint(x: 120, y: 50), in: region, window: window)
            region.handleLocalEvent(inside)
            region.removeFromSuperview()
            await flush()
            #expect(updates.isEmpty)
            #expect(region.trackingAreas.isEmpty)
            row.addSubview(region, positioned: .below, relativeTo: nil)
            region.refreshAttachment()
            region.handleLocalEvent(inside)
            await flush()
            #expect(updates == [true])
            let mouseMoveSetting = window.acceptsMouseMovedEvents
            region.refreshAttachment()
            region.refreshAttachment()
            #expect(region.trackingAreas.count == 1)
            #expect(window.acceptsMouseMovedEvents == mouseMoveSetting)
            region.handleLocalEvent(try event(.mouseMoved, at: CGPoint(x: -20, y: 50), in: region, window: window))
            region.stop()
            region.handleLocalEvent(inside)
            await flush()
            #expect(updates == [true])
            #expect(!region.isPointerInside)
            #expect(region.trackingAreas.isEmpty)
        }
    }

    @Test func hiddenRowsAndWindowDeactivationClearHoverWithoutResamplingThePhysicalCursor() async throws {
        try await withRegion { window, _, row, region in
            var updates: [Bool] = []
            region.onChange = { updates.append($0) }
            let inside = try event(.mouseMoved, at: CGPoint(x: 120, y: 50), in: region, window: window)
            region.handleLocalEvent(inside)
            await flush()
            row.isHidden = true
            region.refreshAttachment()
            await flush()
            #expect(updates == [true, false])
            row.isHidden = false
            region.refreshAttachment()
            await flush()
            #expect(updates == [true, false, true])
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            await flush()
            region.refreshAttachment()
            await flush()
            #expect(updates == [true, false, true, false])
            #expect(!region.isPointerInside)
        }
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in region: NSView, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: region.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    private func flush() async {
        for _ in 0..<3 { await Task.yield() }
    }

    private func withRegion(_ body: (NSWindow, NSScrollView, NSView, YapHoverTrackingView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let window = HoverFixtureWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 600, height: 400),
                                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: 400, height: 250))
        scroll.automaticallyAdjustsContentInsets = false
        try #require(window.contentView).addSubview(scroll)
        let document = HoverFixtureDocument(frame: CGRect(x: 0, y: 0, width: 400, height: 650))
        scroll.documentView = document
        let row = NSView(frame: CGRect(x: 20, y: 80, width: 340, height: 100))
        document.addSubview(row)
        let region = YapHoverTrackingView(frame: row.bounds)
        region.autoresizingMask = [.width, .height]
        row.addSubview(region)
        region.refreshAttachment()
        defer { region.stop(); window.close() }
        try await body(window, scroll, row, region)
    }
}

@MainActor private final class HoverFixtureWindow: NSWindow {
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { false }
}

@MainActor private final class HoverFixtureDocument: NSView {
    override var isFlipped: Bool { true }
}
