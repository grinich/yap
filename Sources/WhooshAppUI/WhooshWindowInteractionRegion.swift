import AppKit
import SwiftUI

/// Keeps a titlebar-overlapping control's pointer sequence out of window dragging.
/// The control still receives the original events and owns its native tracking.
@MainActor
struct WhooshWindowInteractionRegion: NSViewRepresentable {
    var isEnabled = true
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> WhooshWindowInteractionTrackingView {
        let view = WhooshWindowInteractionTrackingView()
        view.isEnabled = isEnabled && environmentEnabled
        return view
    }

    func updateNSView(_ view: WhooshWindowInteractionTrackingView, context: Context) {
        view.isEnabled = isEnabled && environmentEnabled
        view.refreshAttachment()
    }

    static func dismantleNSView(_ view: WhooshWindowInteractionTrackingView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class WhooshWindowInteractionTrackingView: NSView {
    var isEnabled = true {
        didSet { if !isEnabled { finishInteraction() } }
    }
    private weak var observedWindow: NSWindow?
    private var localMonitor: Any?
    private var savedMovability: Bool?

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
        savedMovability = window.isMovable
        window.isMovable = false
    }

    @objc private func interactionEnded(_ notification: Notification) { finishInteraction() }

    private func finishInteraction() {
        guard let savedMovability else { return }
        observedWindow?.isMovable = savedMovability
        self.savedMovability = nil
    }

    func detach() {
        finishInteraction()
        NotificationCenter.default.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        observedWindow = nil
    }
}
