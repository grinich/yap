import AppKit
import SwiftUI

/// Keeps a titlebar-overlapping control's pointer sequence out of window dragging.
/// The control still receives the original events and owns its native tracking.
@MainActor
struct YapWindowInteractionRegion: NSViewRepresentable {
    var isEnabled = true
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> YapWindowInteractionTrackingView {
        let view = YapWindowInteractionTrackingView()
        view.isEnabled = isEnabled && environmentEnabled
        return view
    }

    func updateNSView(_ view: YapWindowInteractionTrackingView, context: Context) {
        view.isEnabled = isEnabled && environmentEnabled
        view.refreshAttachment()
    }

    static func dismantleNSView(_ view: YapWindowInteractionTrackingView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class YapWindowInteractionTrackingView: NSView {
    var isEnabled = true {
        didSet { if !isEnabled { finishInteraction() } }
    }
    private weak var observedWindow: NSWindow?
    private var localMonitor: Any?
    private var movabilitySuspension: YapWindowMovabilitySuspension?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAttachment()
    }

    func refreshAttachment() {
        guard observedWindow !== window else { return }
        detach()
        guard let window else { return }
        observedWindow = window
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalEvent(event) }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interactionEnded),
            name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interactionEnded),
            name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(interactionEnded), name: name, object: window)
        }
    }

    func handleLocalEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
            finishInteraction()
            return
        }
        guard event.type == .leftMouseDown else { return }
        finishInteraction()
        guard isEnabled, !isHiddenOrHasHiddenAncestor,
              let window = observedWindow, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        movabilitySuspension = YapWindowMovabilitySuspension.acquire(in: window)
    }

    @objc private func interactionEnded(_ notification: Notification) { finishInteraction() }

    private func finishInteraction() {
        movabilitySuspension?.release()
        movabilitySuspension = nil
    }

    func detach() {
        finishInteraction()
        NotificationCenter.default.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        observedWindow = nil
    }
}

/// Nested regions share the original state. Releasing an outer region cannot
/// enable dragging while an inner control is still tracking, or restore a stale false.
@MainActor
private final class YapWindowMovabilitySuspension {
    private static let active = NSMapTable<NSWindow, YapWindowMovabilitySuspension>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private weak var window: NSWindow?
    private let originalMovability: Bool
    private var owners = 1

    private init(window: NSWindow) {
        self.window = window
        originalMovability = window.isMovable
        window.isMovable = false
    }

    static func acquire(in window: NSWindow) -> YapWindowMovabilitySuspension {
        if let suspension = active.object(forKey: window) {
            suspension.owners += 1
            return suspension
        }
        let suspension = YapWindowMovabilitySuspension(window: window)
        active.setObject(suspension, forKey: window)
        return suspension
    }

    func release() {
        owners -= 1
        guard owners == 0, let window else { return }
        window.isMovable = originalMovability
        Self.active.removeObject(forKey: window)
    }
}
