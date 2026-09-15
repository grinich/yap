import AppKit
import SwiftUI

/// Passive row-wide hover, including native text and controls layered above it.
@MainActor
struct YapHoverRegion: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> YapHoverTrackingView {
        let view = YapHoverTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: YapHoverTrackingView, context: Context) {
        view.onChange = onChange
        view.refreshAttachment()
    }

    static func dismantleNSView(_ view: YapHoverTrackingView, coordinator: ()) { view.stop() }
}

@MainActor
final class YapHoverTrackingView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private(set) var isPointerInside = false
    private weak var observedWindow: NSWindow?
    private let observedAncestors = NSHashTable<NSView>.weakObjects()
    private var trackingArea: NSTrackingArea?
    private var localMonitor: Any?
    private var pointerOnScreen: CGPoint?
    private var deliveredValue = false
    private var delivery: Task<Void, Never>?
    private var attachmentRevision = UUID()
    private var stopped = false

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshAttachment() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refreshAttachment() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); refreshAttachment() }
    override func layout() { super.layout(); refreshAttachment() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); refreshPresence() }
    override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); refreshPresence() }
    override func setBoundsSize(_ size: NSSize) { super.setBoundsSize(size); refreshPresence() }
    override func setBoundsOrigin(_ origin: NSPoint) { super.setBoundsOrigin(origin); refreshPresence() }
    override func viewDidHide() { super.viewDidHide(); refreshPresence() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshPresence() }

    func refreshAttachment() {
        guard !stopped else { return }
        var ancestors: [NSView] = []
        var ancestor = superview
        while let current = ancestor { ancestors.append(current); ancestor = current.superview }
        let changedWindow = observedWindow !== window
        let changedAncestors = ancestors.count != observedAncestors.count ||
            ancestors.contains { !observedAncestors.contains($0) }
        if changedWindow || changedAncestors || (window != nil && localMonitor == nil) {
            // Keep a delivered event's position across same-window row reflow.
            // Replacing the window invalidates both that position and queued work.
            let pointer = changedWindow ? nil : pointerOnScreen
            detachObservers()
            pointerOnScreen = pointer
            observedWindow = window
            if let window {
                let area = NSTrackingArea(rect: .zero,
                    options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                    owner: self, userInfo: nil)
                addTrackingArea(area)
                trackingArea = area
                for view in ancestors {
                    observedAncestors.add(view)
                    view.postsFrameChangedNotifications = true
                    view.postsBoundsChangedNotifications = true
                    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: name, object: view)
                    }
                }
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                             NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
                    name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                    .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
                ]) { [weak self] event in
                    MainActor.assumeIsolated { self?.handleLocalEvent(event) }
                    return event
                }
                if pointerOnScreen == nil, NSApplication.shared.isActive, window.isKeyWindow {
                    pointerOnScreen = NSEvent.mouseLocation
                }
            }
        }
        refreshPresence()
    }

    /// Delivered positions remain authoritative during passive layout/scroll
    /// updates; remote input need not move the physical system cursor.
    func handleLocalEvent(_ event: NSEvent) {
        guard !stopped, let window = observedWindow, event.window === window,
              event.locationInWindow.x.isFinite, event.locationInWindow.y.isFinite else { return }
        pointerOnScreen = window.convertPoint(toScreen: event.locationInWindow)
        refreshPresence()
    }

    override func mouseEntered(with event: NSEvent) { handleLocalEvent(event) }
    override func mouseMoved(with event: NSEvent) { handleLocalEvent(event) }
    override func mouseExited(with event: NSEvent) {
        // Moving over a toolbar/native child can alter native tracking targets
        // while the pointer is still inside the padded row. Geometry decides.
        handleLocalEvent(event)
    }

    @objc private func geometryChanged(_ notification: Notification) { refreshPresence() }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification ||
            notification.name == NSWindow.didMiniaturizeNotification ||
            notification.name == NSWindow.willCloseNotification ||
            (notification.name == NSWindow.didChangeOcclusionStateNotification &&
             observedWindow?.occlusionState.contains(.visible) != true) {
            pointerOnScreen = nil
        }
        refreshPresence()
    }

    @objc private func applicationDeactivated(_ notification: Notification) {
        pointerOnScreen = nil
        refreshPresence()
    }

    private func refreshPresence() {
        guard !stopped else { return }
        var inside = false
        if let window = observedWindow, self.window === window, window.isVisible, !window.isMiniaturized,
           !isHiddenOrHasHiddenAncestor, let pointer = pointerOnScreen {
            let clipped = bounds.intersection(visibleRect)
            let point = convert(window.convertPoint(fromScreen: pointer), from: nil)
            inside = !clipped.isNull && !clipped.isEmpty && clipped.contains(point)
        }
        isPointerInside = inside
        guard inside != deliveredValue || delivery != nil else { return }
        guard delivery == nil else { return }
        let revision = attachmentRevision
        // SwiftUI can lay out the row while inserting/updating its toolbar.
        // Publish the final value after that turn, never an intermediate exit.
        delivery = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !self.stopped, self.attachmentRevision == revision else { return }
            self.delivery = nil
            guard self.isPointerInside != self.deliveredValue else { return }
            self.deliveredValue = self.isPointerInside
            self.onChange(self.isPointerInside)
        }
    }

    func stop() {
        stopped = true
        isPointerInside = false
        detachObservers()
    }

    private func detachObservers() {
        attachmentRevision = UUID()
        delivery?.cancel()
        delivery = nil
        NotificationCenter.default.removeObserver(self)
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        observedAncestors.removeAllObjects()
        observedWindow = nil
        pointerOnScreen = nil
    }
}
