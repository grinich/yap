import AppKit
import Testing
@testable import YapAppUI

@Suite("Received share local viewport", .serialized) @MainActor
struct ReceivedShareViewportTests {
    @Test func pinchKeepsTheContentUnderItsAnchorAndNeverResizesOrRecreatesTheRenderer() throws {
        try withViewport { window, viewport, renderer in
            let anchor = CGPoint(x: 220, y: 160)
            let contentPoint = renderer.convert(anchor, from: viewport)
            let originalFrame = renderer.frame
            let event = ViewportGestureEvent(.magnify, location: viewport.convert(anchor, to: nil), magnification: 0.5)
            viewport.magnify(with: event)
            #expect(abs(viewport.zoomFactor - 1.5) < 0.001)
            expectClose(renderer.convert(anchor, from: viewport), contentPoint)
            #expect(renderer.frame == originalFrame)
            #expect(renderer.superview === viewport.documentView)
            #expect(renderer.window === window)
            viewport.magnify(with: ViewportGestureEvent(.magnify, location: event.locationInWindow, magnification: -0.2))
            #expect(abs(viewport.zoomFactor - 1.2) < 0.001)
            expectClose(renderer.convert(anchor, from: viewport), contentPoint)
        }
    }

    @Test func zoomBoundsResetAndSmartMagnificationRemainLocal() throws {
        try withViewport { _, viewport, _ in
            viewport.zoom(to: 20)
            #expect(viewport.zoomFactor == 4)
            viewport.pan(by: CGSize(width: 100, height: 100))
            viewport.zoom(to: .nan)
            #expect(viewport.zoomFactor == 4)
            viewport.zoom(to: -2)
            #expect(viewport.zoomFactor == 1)
            expectClose(viewport.contentView.bounds.origin, .zero)
            let doubleTap = ViewportGestureEvent(.smartMagnify, location: CGPoint(x: 400, y: 300))
            viewport.smartMagnify(with: doubleTap)
            #expect(viewport.zoomFactor == 2)
            viewport.smartMagnify(with: doubleTap)
            #expect(viewport.zoomFactor == 1)
            viewport.zoom(to: 3)
            viewport.pan(by: CGSize(width: 200, height: 120))
            viewport.resetToFit()
            #expect(viewport.zoomFactor == 1)
            expectClose(viewport.contentView.bounds.origin, .zero)
        }
    }

    @Test func preciseTwoFingerScrollingAndMomentumPanBothAxesAndClampAtEdges() throws {
        try withViewport { _, viewport, _ in
            let gesture = ViewportGestureEvent(.scrollWheel, scrollX: -80, scrollY: -40, precise: true)
            viewport.scrollWheel(with: gesture)
            expectClose(viewport.contentView.bounds.origin, .zero)
            viewport.zoom(to: 2)
            let start = viewport.contentView.bounds.origin
            viewport.scrollWheel(with: gesture)
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 40, y: start.y + 20))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollX: 20, scrollY: 10,
                                                           precise: true, momentum: .changed))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 30, y: start.y + 15))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollX: -100_000, scrollY: -100_000, precise: true))
            let document = try #require(viewport.documentView)
            #expect(abs(viewport.contentView.bounds.maxX - document.bounds.maxX) < 0.001)
            #expect(abs(viewport.contentView.bounds.maxY - document.bounds.maxY) < 0.001)
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollX: 100_000, scrollY: 100_000, precise: true))
            expectClose(viewport.contentView.bounds.origin, .zero)
        }
    }

    @Test func sourceAndRendererRefreshesHaveDistinctResetBehavior() throws {
        try withViewport { _, viewport, renderer in
            viewport.zoom(to: 2)
            viewport.pan(by: CGSize(width: 40, height: 20))
            let visible = viewport.contentView.bounds
            viewport.display(renderer, sourceID: "first")
            #expect(viewport.zoomFactor == 2)
            #expect(viewport.contentView.bounds == visible)
            viewport.display(renderer, sourceID: "second")
            #expect(viewport.zoomFactor == 1)
            #expect(renderer.superview === viewport.documentView)
            viewport.zoom(to: 2)
            let replacement = NSView()
            viewport.display(replacement, sourceID: "second")
            #expect(viewport.zoomFactor == 2)
            #expect(renderer.superview == nil)
            #expect(replacement.superview === viewport.documentView)
            viewport.display(nil, sourceID: "second")
            #expect(replacement.superview == nil)
            #expect(viewport.zoomFactor == 1)
            viewport.zoom(to: 3)
            #expect(viewport.zoomFactor == 1)
        }
    }

    @Test func shiftWheelPansHorizontallyWithoutDoubleRemappingExistingHorizontalEvents() throws {
        try withViewport { _, viewport, _ in
            viewport.zoom(to: 2)
            let start = viewport.contentView.bounds.origin
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollY: -3, modifiers: [.shift]))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 18, y: start.y))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollX: -2, modifiers: [.shift]))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 30, y: start.y))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollY: 2))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 30, y: start.y - 12))
        }
    }

    @Test func legacyWheelFallbackDoesNotCombineAxesOrInventTrackpadMotion() throws {
        try withViewport { _, viewport, _ in
            viewport.zoom(to: 2)
            let start = viewport.contentView.bounds.origin
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, legacyX: -2))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 12, y: start.y))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, modifiers: [.shift], legacyY: -2))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 24, y: start.y))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, scrollX: -1, legacyX: -30, legacyY: -10))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 30, y: start.y))
            viewport.scrollWheel(with: ViewportGestureEvent(.scrollWheel, precise: true, momentum: .ended, legacyX: -20))
            expectClose(viewport.contentView.bounds.origin, CGPoint(x: start.x + 30, y: start.y))
        }
    }

    @Test func resizePreservesTheNormalizedVisibleCenterAndFitsTheSameRenderer() throws {
        try withViewport { _, viewport, renderer in
            viewport.zoom(to: 2)
            viewport.pan(by: CGSize(width: 80, height: 50))
            let original = normalizedCenter(viewport)
            viewport.setFrameSize(CGSize(width: 1_000, height: 800))
            viewport.layoutSubtreeIfNeeded()
            expectClose(normalizedCenter(viewport), original)
            #expect(viewport.zoomFactor == 2)
            #expect(renderer.frame.size == viewport.contentView.frame.size)
            #expect(renderer.superview === viewport.documentView)
            viewport.resetToFit()
            viewport.setFrameSize(CGSize(width: 640, height: 400))
            viewport.layoutSubtreeIfNeeded()
            #expect(renderer.frame.size == viewport.contentView.frame.size)
            #expect(viewport.contentView.bounds.size == viewport.contentView.frame.size)
            expectClose(viewport.contentView.bounds.origin, .zero)
        }
    }

    @Test func nativeHitTestingShieldsSDKChildrenAndAnOutgoingMountCannotDetachTheNewOwner() throws {
        try withViewport { _, viewport, renderer in
            let sdkChild = NSView(frame: renderer.bounds)
            renderer.addSubview(sdkChild)
            #expect(viewport.hitTest(CGPoint(x: 300, y: 250)) === viewport)
            #expect(viewport.hitTest(CGPoint(x: -20, y: -20)) == nil)
            #expect(!viewport.mouseDownCanMoveWindow)
            let replacementViewport = ReceivedShareViewport(frame: viewport.frame)
            replacementViewport.display(renderer, sourceID: "first")
            let ownedFrame = renderer.frame
            viewport.setFrameSize(CGSize(width: 300, height: 200))
            viewport.layoutSubtreeIfNeeded()
            #expect(renderer.frame == ownedFrame)
            viewport.display(nil, sourceID: "first")
            #expect(renderer.superview === replacementViewport.documentView)
        }
    }

    @Test func zoomUpdatesReportActualChangesWithoutReplayingStableRepresentableUpdates() throws {
        try withViewport { _, viewport, renderer in
            var updates: [CGFloat] = []
            viewport.zoomDidChange = { updates.append($0) }
            viewport.zoom(to: 2)
            viewport.display(renderer, sourceID: "first")
            viewport.zoom(to: 2)
            viewport.pan(by: CGSize(width: 20, height: 20))
            viewport.resetToFit()
            #expect(updates == [2, 1])
        }
    }

    private func normalizedCenter(_ viewport: ReceivedShareViewport) -> CGPoint {
        let size = viewport.documentView?.bounds.size ?? .zero
        return CGPoint(x: viewport.contentView.bounds.midX / size.width,
                       y: viewport.contentView.bounds.midY / size.height)
    }

    private func expectClose(_ actual: CGPoint, _ expected: CGPoint, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.x - expected.x) < 0.001 && abs(actual.y - expected.y) < 0.001,
                "Expected \(expected); got \(actual)", sourceLocation: sourceLocation)
    }

    private func withViewport(_ body: (NSWindow, ReceivedShareViewport, NSView) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let viewport = ReceivedShareViewport(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        try #require(window.contentView).addSubview(viewport)
        let renderer = NSView()
        viewport.display(renderer, sourceID: "first")
        viewport.layoutSubtreeIfNeeded()
        defer { viewport.display(nil, sourceID: "first"); window.close() }
        try body(window, viewport, renderer)
    }
}

/// Inert event values exercise the actual native handlers without posting
/// operating-system input, activating another app, or opening an SDK stream.
private final class ViewportGestureEvent: NSEvent {
    private let kind: NSEvent.EventType
    private let point: CGPoint
    private let magnifyDelta: CGFloat
    private let xDelta: CGFloat
    private let yDelta: CGFloat
    private let precise: Bool
    private let momentum: NSEvent.Phase
    private let modifiers: NSEvent.ModifierFlags
    private let legacyX: CGFloat
    private let legacyY: CGFloat

    init(_ kind: NSEvent.EventType, location: CGPoint = .zero, magnification: CGFloat = 0,
         scrollX: CGFloat = 0, scrollY: CGFloat = 0, precise: Bool = false, momentum: NSEvent.Phase = [],
         modifiers: NSEvent.ModifierFlags = [], legacyX: CGFloat = 0, legacyY: CGFloat = 0) {
        self.kind = kind; self.point = location; self.magnifyDelta = magnification
        self.xDelta = scrollX; self.yDelta = scrollY; self.precise = precise; self.momentum = momentum
        self.modifiers = modifiers; self.legacyX = legacyX; self.legacyY = legacyY
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Use the inert event initializer") }
    override var type: NSEvent.EventType { kind }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { magnifyDelta }
    override var scrollingDeltaX: CGFloat { xDelta }
    override var scrollingDeltaY: CGFloat { yDelta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var deltaX: CGFloat { legacyX }
    override var deltaY: CGFloat { legacyY }
}
