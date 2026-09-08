import AppKit
import SwiftUI

enum PictureInPictureCorner: CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    func rect(in bounds: CGRect) -> CGRect {
        CGRect(x: isLeft ? bounds.minX : bounds.maxX - 16,
               y: isTop ? bounds.maxY - 16 : bounds.minY, width: 16, height: 16)
    }
    var position: NSCursor.FrameResizePosition {
        switch self {
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        case .topLeft: .topLeft
        case .topRight: .topRight
        }
    }
}

enum PictureInPictureResize {
    static func frame(from original: CGRect, translation: CGSize, minimum: CGSize, maximum: CGSize,
                      corner: PictureInPictureCorner = .bottomRight) -> CGRect {
        guard translation.width.isFinite, translation.height.isFinite else { return original }
        let width = min(maximum.width, max(minimum.width, original.width + translation.width * (corner.isLeft ? -1 : 1)))
        let height = min(maximum.height, max(minimum.height, original.height + translation.height * (corner.isTop ? 1 : -1)))
        return CGRect(x: corner.isLeft ? original.maxX - width : original.minX,
                      y: corner.isTop ? original.minY : original.maxY - height, width: width, height: height)
    }
}

/// Own video gestures in AppKit; controls get their own hosting surface and hit testing.
@MainActor
final class SharingPictureInPictureView<Content: View, Controls: View>: NSView {
    static var controlsHeight: CGFloat { 52 }
    var interactionChanged: ((Bool) -> Void)?
    var openMeeting: (() -> Void)?
    private let content: NSHostingView<Content>
    private let controls: PictureInPictureControlsHost<Controls>
    private var originalFrame: CGRect?
    private var pointerOrigin: CGPoint?
    private var resizing: PictureInPictureCorner?
    private var didDrag = false

    init(rootView: Content, controls: Controls) {
        content = NSHostingView(rootView: rootView)
        self.controls = PictureInPictureControlsHost(rootView: controls)
        super.init(frame: .zero)
        content.sizingOptions = []
        self.controls.sizingOptions = []
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        addSubview(content)
        addSubview(self.controls)
        toolTip = "Click the video to return to Yap. Drag to move; drag any corner to resize."
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:controls:)") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        controls.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.controlsHeight)
        content.frame = CGRect(x: 0, y: Self.controlsHeight, width: bounds.width,
                               height: max(0, bounds.height - Self.controlsHeight))
        window?.invalidateCursorRects(for: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if PictureInPictureCorner.allCases.contains(where: { $0.rect(in: bounds).contains(local) }) { return self }
        if controls.frame.contains(local) { return super.hitTest(point) }
        return self
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(content.frame, cursor: .openHand)
        for corner in PictureInPictureCorner.allCases {
            addCursorRect(corner.rect(in: bounds), cursor: .frameResize(position: corner.position, directions: .all))
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        originalFrame = window.frame
        pointerOrigin = window.convertPoint(toScreen: event.locationInWindow)
        resizing = PictureInPictureCorner.allCases.first { $0.rect(in: bounds).contains(convert(event.locationInWindow, from: nil)) }
        didDrag = false
        interactionChanged?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let originalFrame, let pointerOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: point.x - pointerOrigin.x, height: point.y - pointerOrigin.y)
        guard didDrag || hypot(delta.width, delta.height) >= 4 else { return }
        didDrag = true
        if let resizing {
            window.setFrame(PictureInPictureResize.frame(from: originalFrame, translation: delta,
                minimum: window.minSize, maximum: window.maxSize, corner: resizing), display: true)
        } else {
            NSCursor.closedHand.set()
            window.setFrameOrigin(CGPoint(x: originalFrame.minX + delta.width, y: originalFrame.minY + delta.height))
        }
    }
    override func mouseUp(with event: NSEvent) {
        let shouldOpen = originalFrame != nil && !didDrag && resizing == nil
        originalFrame = nil
        pointerOrigin = nil
        resizing = nil
        didDrag = false
        interactionChanged?(false)
        window?.invalidateCursorRects(for: self)
        if shouldOpen { openMeeting?() }
    }
}

@MainActor
private final class PictureInPictureControlsHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
