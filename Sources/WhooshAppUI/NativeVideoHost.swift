import AppKit
import OSLog

@MainActor
class NativeVideoHost: NSView {
    /// Weak keys do not extend the SDK renderer's lifetime. A lease belongs
    /// only to an attached mount and cannot retain a disappearing container.
    private static let leases = NSMapTable<NSView, NativeVideoLease>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var nextMount: UInt64 = 0
    private static let logger = Logger(subsystem: "app.whoosh.zoom", category: "video-host")

    private var mount: UInt64 = 0
    private var renderer: NSView?
    private var isDismantled = false
    private var isReconciling = false
    private var lastDeferred: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func setRenderer(_ next: NSView?) {
        guard !isDismantled else { return }
        if renderer !== next {
            releaseRenderer()
            renderer = next
            log(next == nil ? "renderer-absent" : "renderer-present")
        }
        reconcileRenderer()
    }

    /// Mount order belongs to real attachment, not SwiftUI allocation/probing.
    /// An unattached or zero-sized replacement cannot take a visible renderer.
    var hasUsableAttachment: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor &&
            frame.width.isFinite && frame.height.isFinite && frame.width >= 1 && frame.height >= 1 &&
            bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width >= 1 && bounds.height >= 1
    }

    private func reconcileRenderer() {
        guard !isDismantled, !isReconciling else { return }
        guard let renderer else { return }
        isReconciling = true
        defer { isReconciling = false }
        let lease: NativeVideoLease
        if let existing = Self.leases.object(forKey: renderer) {
            lease = existing
        } else {
            lease = NativeVideoLease()
            Self.leases.setObject(lease, forKey: renderer)
        }
        guard hasUsableAttachment else {
            if lease.owner === self { lease.owner = nil }
            if lastDeferred != true { log("deferred") }
            lastDeferred = true
            return
        }
        lastDeferred = false
        if mount == 0 { Self.nextMount += 1; mount = Self.nextMount }
        // A late update from an outgoing branch must not steal the renderer
        // from its attached replacement. A detached owner has no lasting claim.
        if let owner = lease.owner, owner !== self,
           owner.hasUsableAttachment, owner.mount > mount { return }
        // Always deliver the actual viewport to the SDK. Keeping a large
        // logical bounds rectangle in a tiny host can clip native video layers
        // instead of scaling them. The renderer and subscription remain alive.
        if lease.owner !== self { lease.owner?.releaseOwnedRenderer() }
        lease.owner = self
        if renderer.superview !== self {
            renderer.removeFromSuperview()
            renderer.frame = bounds
            renderer.autoresizingMask = [.width, .height]
            addSubview(renderer)
            log("attached")
        } else if renderer.frame != bounds {
            renderer.frame = bounds
            log("resized")
        }
    }

    override func layout() { super.layout(); reconcileRenderer() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reconcileRenderer() }
    override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); reconcileRenderer() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { mount = 0 }
        log("window")
        reconcileRenderer()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); reconcileRenderer() }
    override func viewDidHide() { super.viewDidHide(); reconcileRenderer() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcileRenderer() }

    func dismantle() {
        isDismantled = true
        releaseRenderer()
        log("dismantled")
    }

    private func releaseRenderer() {
        releaseOwnedRenderer()
        renderer = nil
    }

    private func releaseOwnedRenderer() {
        guard let renderer else { return }
        if renderer.superview === self { renderer.removeFromSuperview() }
        if let lease = Self.leases.object(forKey: renderer), lease.owner === self {
            lease.owner = nil
        }
    }

    private func log(_ phase: String) {
        Self.logger.info("host=\(phase, privacy: .public) mount=\(self.mount) window=\(self.window != nil) usable=\(self.hasUsableAttachment) renderer=\(self.renderer != nil) owned=\(self.renderer?.superview === self) width=\(Double(self.bounds.width)) height=\(Double(self.bounds.height)) displayWidth=\(Double(self.frame.width)) displayHeight=\(Double(self.frame.height))")
    }
}

@MainActor
private final class NativeVideoLease {
    weak var owner: NativeVideoHost?
}
