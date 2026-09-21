import AppKit

/// A local viewing transform around the single renderer owned by the meeting SDK.
/// Magnification never changes the share subscription or forwards remote input.
@MainActor
final class ReceivedShareViewport: NSScrollView {
    static let zoomRange: ClosedRange<CGFloat> = 1...4
    var zoomDidChange: ((CGFloat) -> Void)?
    var zoomFactor: CGFloat { magnification }

    private let canvas = ReceivedShareCanvas()
    private let placeholder = NSTextField(labelWithString: "Waiting for shared content…")
    private weak var receivedView: NSView?
    private var sourceID: String?
    private var fittedSize = CGSize.zero
    private var pendingResizeCenter: CGPoint?
    private var isConfigured = false
    private var isUpdatingGeometry = false
    private var lastPublishedZoom: CGFloat = 1

    convenience init() { self.init(frame: .zero) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .black
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsetsZero
        allowsMagnification = true
        minMagnification = Self.zoomRange.lowerBound
        maxMagnification = Self.zoomRange.upperBound
        documentView = canvas
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        canvas.addSubview(placeholder)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shared content")
        setAccessibilityHelp("Pinch to zoom. When zoomed in, scroll with two fingers to move around the shared content.")
        isConfigured = true
        updateFittedGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var mouseDownCanMoveWindow: Bool { false }

    func display(_ view: NSView?, sourceID: String) {
        let changedSource = self.sourceID != sourceID
        self.sourceID = sourceID
        if receivedView !== view {
            // A dismantled outgoing SwiftUI mount must not remove a renderer
            // that has already been reparented to its replacement.
            if receivedView?.superview === canvas { receivedView?.removeFromSuperview() }
            receivedView = view
            if let view {
                view.removeFromSuperview()
                view.frame = canvas.bounds
                view.autoresizingMask = [.width, .height]
                canvas.addSubview(view)
            }
        }
        placeholder.isHidden = view != nil
        if changedSource || view == nil { resetToFit() }
        updateFittedGeometry()
    }

    func resetToFit() {
        setMagnification(1, centeredAt: contentView.bounds.origin)
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
        publishZoomIfNeeded()
    }

    /// Toolbar zoom keeps the visible center fixed; pinch uses its actual anchor.
    func zoom(to factor: CGFloat) { setZoomFactor(factor) }

    func setZoomFactor(_ factor: CGFloat, anchoredAt point: NSPoint? = nil) {
        guard receivedView != nil, factor.isFinite else { return }
        updateFittedGeometry()
        guard fittedSize.width > 0, fittedSize.height > 0 else { return }
        let desired = min(max(factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let viewportPoint = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = contentView.convert(viewportPoint, from: self)
        // AppKit preserves this content-view point's screen position while
        // magnifying, and constrains the resulting clip rectangle to the document.
        setMagnification(desired, centeredAt: anchor)
        clampVisibleOrigin()
        publishZoomIfNeeded()
    }

    /// Positive deltas move the viewport through the document in view points.
    func pan(by delta: CGSize) {
        guard zoomFactor > 1, delta.width.isFinite, delta.height.isFinite else { return }
        let origin = contentView.bounds.origin
        scroll(to: CGPoint(x: origin.x + delta.width / zoomFactor,
                           y: origin.y + delta.height / zoomFactor))
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification.isFinite else { return }
        setZoomFactor(zoomFactor * max(0, 1 + event.magnification),
                      anchoredAt: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if zoomFactor > 1.001 { resetToFit() }
        else { setZoomFactor(2, anchoredAt: convert(event.locationInWindow, from: nil)) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Swallow fit-size/edge gestures so they cannot navigate the meeting or
        // reach an SDK child that interprets scrolling as remote-control input.
        guard receivedView != nil, zoomFactor > 1 else { return }
        let precise = event.hasPreciseScrollingDeltas
        var horizontal = event.scrollingDeltaX
        var vertical = event.scrollingDeltaY
        // Older wheel event producers can provide only the legacy line deltas.
        // Never combine them with populated preferred deltas or trackpad phases.
        if !precise, horizontal == 0, vertical == 0 {
            horizontal = event.deltaX
            vertical = event.deltaY
        }
        // AppKit sometimes already remaps Shift-wheel into deltaX. Only remap
        // an exclusively vertical event so a horizontal event is not swapped twice.
        if event.modifierFlags.contains(.shift), horizontal == 0 {
            horizontal = vertical
            vertical = 0
        }
        let multiplier: CGFloat = precise ? 1 : 12
        pan(by: CGSize(width: -horizontal * multiplier, height: -vertical * multiplier))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func layout() {
        super.layout()
        updateFittedGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if isConfigured, newSize != frame.size, fittedSize.width > 0, fittedSize.height > 0 {
            pendingResizeCenter = CGPoint(x: contentView.bounds.midX / fittedSize.width,
                                          y: contentView.bounds.midY / fittedSize.height)
        }
        super.setFrameSize(newSize)
        updateFittedGeometry()
    }

    private func updateFittedGeometry() {
        guard isConfigured, !isUpdatingGeometry else { return }
        let size = contentView.frame.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        guard size != fittedSize else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        let visible = contentView.bounds
        let center = pendingResizeCenter ?? CGPoint(x: fittedSize.width > 0 ? visible.midX / fittedSize.width : 0.5,
                                                   y: fittedSize.height > 0 ? visible.midY / fittedSize.height : 0.5)
        pendingResizeCenter = nil
        fittedSize = size
        canvas.frame = CGRect(origin: .zero, size: size)
        if receivedView?.superview === canvas { receivedView?.frame = canvas.bounds }
        placeholder.frame = CGRect(x: 12, y: max(0, (size.height - 20) / 2),
                                   width: max(0, size.width - 24), height: 20)
        if zoomFactor <= 1.001 { scroll(to: .zero) }
        else {
            scroll(to: CGPoint(x: center.x * size.width - contentView.bounds.width / 2,
                               y: center.y * size.height - contentView.bounds.height / 2))
        }
    }

    private func clampVisibleOrigin() { scroll(to: contentView.bounds.origin) }

    private func scroll(to origin: CGPoint) {
        var proposed = contentView.bounds
        proposed.origin = origin
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }

    private func publishZoomIfNeeded() {
        guard abs(lastPublishedZoom - zoomFactor) > 0.0001 else { return }
        lastPublishedZoom = zoomFactor
        zoomDidChange?(zoomFactor)
    }
}

@MainActor
private final class ReceivedShareCanvas: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
