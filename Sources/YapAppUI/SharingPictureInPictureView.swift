import AppKit
import SwiftUI

enum PictureInPictureResize {
    static func frame(from original: CGRect, translation: CGSize, minimum: CGSize, maximum: CGSize) -> CGRect {
        guard translation.width.isFinite, translation.height.isFinite else { return original }
        let width = min(maximum.width, max(minimum.width, original.width + translation.width))
        let height = min(maximum.height, max(minimum.height, original.height - translation.height))
        return CGRect(x: original.minX, y: original.maxY - height, width: width, height: height)
    }
}

/// The video is a display surface; this native wrapper owns pointer tracking so
/// dragging does not activate the meeting, disappear on hover, or lose mouse-up.
@MainActor
final class SharingPictureInPictureView<Content: View>: NSView {
    var interactionChanged: ((Bool) -> Void)?
    private let content: NSHostingView<Content>
    private let resizeHandle = PictureInPictureResizeHandle(frame: .zero)
    private var originalFrame: CGRect?
    private var pointerOrigin: CGPoint?
    private var resizing = false

    init(rootView: Content) {
        content = NSHostingView(rootView: rootView)
        content.sizingOptions = []
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        addSubview(resizeHandle)
        resizeHandle.resizeBy = { [weak self] factor in
            guard let self, let window else { return }
            window.setFrame(PictureInPictureResize.frame(from: window.frame,
                translation: CGSize(width: window.frame.width * factor, height: -window.frame.height * factor),
                minimum: window.minSize, maximum: window.maxSize), display: true)
            interactionChanged?(false)
        }
        toolTip = "Drag to move. Drag the lower-right corner to resize."
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        content.frame = bounds
        resizeHandle.frame = CGRect(x: max(0, bounds.maxX - 28), y: 0, width: 28, height: 28)
        window?.invalidateCursorRects(for: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(resizeHandle.frame, cursor: .frameResize(position: .bottomRight, directions: .all))
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        originalFrame = window.frame
        pointerOrigin = window.convertPoint(toScreen: event.locationInWindow)
        resizing = resizeHandle.frame.contains(convert(event.locationInWindow, from: nil))
        interactionChanged?(true)
        if !resizing { NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let originalFrame, let pointerOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: point.x - pointerOrigin.x, height: point.y - pointerOrigin.y)
        if resizing {
            window.setFrame(PictureInPictureResize.frame(from: originalFrame, translation: delta,
                minimum: window.minSize, maximum: window.maxSize), display: true)
        } else {
            window.setFrameOrigin(CGPoint(x: originalFrame.minX + delta.width, y: originalFrame.minY + delta.height))
        }
    }
    override func mouseUp(with event: NSEvent) {
        originalFrame = nil
        pointerOrigin = nil
        resizing = false
        interactionChanged?(false)
        window?.invalidateCursorRects(for: self)
    }
}

@MainActor
private final class PictureInPictureResizeHandle: NSView {
    var resizeBy: ((CGFloat) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Resize picture in picture")
        toolTip = "Drag to resize"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func accessibilityPerformIncrement() -> Bool { resizeBy?(0.15); return true }
    override func accessibilityPerformDecrement() -> Bool { resizeBy?(-0.15); return true }
}
