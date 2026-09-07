import AppKit
import SwiftUI

/// Kept independent of meeting credentials so the real representable can be
/// exercised in a standalone AppKit/SwiftUI window with a harmless renderer.
struct NativeRendererContainer: NSViewRepresentable {
    var renderer: NSView?

    func makeNSView(context: Context) -> NativeVideoHost { NativeVideoHost(frame: .zero) }
    func updateNSView(_ container: NativeVideoHost, context: Context) {
        container.setRenderer(renderer)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeVideoHost, context: Context) -> CGSize? {
        // An empty SDK host has no useful intrinsic size. Honor the parent tile,
        // including a genuine zero-sized proposal during transitional layout.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 180))
    }
    static func dismantleNSView(_ container: NativeVideoHost, coordinator: ()) {
        container.dismantle()
    }
}
