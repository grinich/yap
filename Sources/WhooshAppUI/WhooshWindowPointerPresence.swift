import AppKit
import SwiftUI

/// Observes the whole containing window without becoming a mouse-event target.
@MainActor
struct WhooshWindowPointerPresence: NSViewRepresentable {
    var onChange: (Bool) -> Void
    var onKeyboardActivity: () -> Void = {}

    func makeNSView(context: Context) -> WhooshWindowPointerTrackingView {
        let view = WhooshWindowPointerTrackingView()
        view.onChange = onChange
        view.onKeyboardActivity = onKeyboardActivity
        return view
    }

    func updateNSView(_ view: WhooshWindowPointerTrackingView, context: Context) {
        view.onChange = onChange
        view.onKeyboardActivity = onKeyboardActivity
        view.refreshAttachment()
    }

    static func dismantleNSView(_ view: WhooshWindowPointerTrackingView, coordinator: ()) { view.stop() }
}

struct WhooshWindowPointerState {
    private(set) var isInside: Bool?

    mutating func update(pointer: CGPoint, windowFrame: CGRect?, isVisible: Bool,
                         isMiniaturized: Bool = false, isOnActiveSpace: Bool = true,
                         isOccluded: Bool = false, isPointerLocationKnown: Bool = true) -> Bool? {
        let inside = isVisible && !isMiniaturized && isOnActiveSpace && !isOccluded && isPointerLocationKnown &&
            windowFrame.map { !$0.isEmpty && $0.contains(pointer) } == true
        guard inside != isInside else { return nil }
        isInside = inside
        return inside
    }
}

@MainActor
final class WhooshWindowPointerTrackingView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    var onKeyboardActivity: () -> Void = {}
    private weak var observedWindow: NSWindow?
    private weak var trackingParent: NSView?
    private var trackingArea: NSTrackingArea?
    private var localMonitor: Any?
    private var state = WhooshWindowPointerState()
    private var pendingValue: Bool?
    private var deliveredValue: Bool?
    private var delivery: Task<Void, Never>?
    private var isPointerLocationKnown = false
    private var stopped = false
    var isPointerInside: Bool { state.isInside == true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAttachment()
    }

    func refreshAttachment() {
        guard !stopped else { return }
        let parent = window?.contentView?.superview ?? window?.contentView
        if observedWindow !== window || trackingParent !== parent {
            detach()
            observedWindow = window
            trackingParent = parent
            if let window, let parent {
                // Initial bounds are reliable only for the active key window.
                // Thereafter native pointer events establish actual presence.
                isPointerLocationKnown = NSApplication.shared.isActive && window.isKeyWindow
                // The window frame includes its titlebar and all native SDK
                // children. Visible-rect tracking follows its resize automatically.
                let area = NSTrackingArea(rect: .zero,
                    options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                    owner: self, userInfo: nil)
                parent.addTrackingArea(area)
                trackingArea = area
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                             NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                                                           name: name, object: window)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
                    name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                    .keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                    .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown
                ]) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.observedWindow, event.window === window else { return }
                        if event.type == .keyDown { self.onKeyboardActivity() }
                        else { self.handlePointerEvent(event, isInside: true) }
                    }
                    return event
                }
            }
            samplePointer()
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification ||
            notification.name == NSWindow.didMiniaturizeNotification ||
            notification.name == NSWindow.willCloseNotification ||
            observedWindow?.occlusionState.contains(.visible) != true {
            isPointerLocationKnown = false
        }
        refreshAttachment()
        samplePointer()
    }
    @objc private func applicationDeactivated(_ notification: Notification) {
        isPointerLocationKnown = false
        samplePointer()
    }
    override func mouseEntered(with event: NSEvent) { handlePointerEvent(event, isInside: true) }
    override func mouseExited(with event: NSEvent) { handlePointerEvent(event, isInside: false) }
    override func mouseMoved(with event: NSEvent) { handlePointerEvent(event, isInside: true) }

    private func handlePointerEvent(_ event: NSEvent, isInside: Bool) {
        guard let window = observedWindow, event.window === window else { return }
        isPointerLocationKnown = isInside
        // The delivered event is authoritative, including native SDK children
        // and remote input whose location can differ from the physical cursor.
        samplePointer(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    private func samplePointer(at pointer: CGPoint? = nil) {
        guard !stopped else { return }
        let window = observedWindow
        guard let changed = state.update(pointer: pointer ?? NSEvent.mouseLocation, windowFrame: window?.frame,
            isVisible: window?.isVisible == true, isMiniaturized: window?.isMiniaturized == true,
            isOnActiveSpace: window?.isOnActiveSpace == true,
            // A delivered event proves access to this window even when the
            // compositor's coarse occlusion metadata has not caught up.
            // Passive geometry and visibility samples still enforce occlusion.
            isOccluded: pointer == nil && window?.occlusionState.contains(.visible) != true,
            isPointerLocationKnown: isPointerLocationKnown) else { return }
        pendingValue = changed
        guard delivery == nil else { return }
        // Native attachment can occur during a SwiftUI update. Deliver afterward,
        // coalescing rapid geometry/enter/exit changes into the current presence.
        delivery = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.delivery = nil
            guard let value = self.pendingValue else { return }
            self.pendingValue = nil
            guard value != self.deliveredValue else { return }
            self.deliveredValue = value
            self.onChange(value)
        }
    }

    func stop() {
        stopped = true
        delivery?.cancel()
        delivery = nil
        pendingValue = nil
        detach()
    }

    private func detach() {
        NotificationCenter.default.removeObserver(self)
        if let trackingArea { trackingParent?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        trackingParent = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        observedWindow = nil
        isPointerLocationKnown = false
    }
}
