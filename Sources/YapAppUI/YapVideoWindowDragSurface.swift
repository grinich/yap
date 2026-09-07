import AppKit
import SwiftUI

/// Sits above the camera renderer, below meeting controls. Gallery tiles keep
/// their own reorder gesture; this surface is used by the focused video layout.
struct YapVideoWindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> VideoWindowDragView { VideoWindowDragView() }
    func updateNSView(_ nsView: VideoWindowDragView, context: Context) {}
}

@MainActor
final class VideoWindowDragView: YapWindowDragView {}
