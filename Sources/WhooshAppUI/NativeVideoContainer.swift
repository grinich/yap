import AppKit
import SwiftUI
import WhooshMeetings

/// Gallery and focus are separate SwiftUI branches, but share one SDK renderer.
/// Their updates and dismantles can overlap during a branch replacement.
struct NativeVideoContainer: View {
    var meeting: MeetingCoordinator
    var participantID: String
    var fillsFrame = false
    var aspectRatio: Double = 16.0 / 9.0

    var body: some View {
        GeometryReader { geometry in
            let size = Self.rendererSize(for: geometry.size, fillsFrame: fillsFrame, aspectRatio: aspectRatio)
            NativeRendererContainer(renderer: meeting.nativeVideoView(for: participantID))
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .clipped()
    }

    /// The SDK exposes a resizable view, not an aspect-fill switch. Center-crop
    /// the incoming video's canvas without changing the stream or user ID.
    /// Participant labels live outside this container and remain fully visible.
    static func rendererSize(for availableSize: CGSize, fillsFrame: Bool, aspectRatio: Double = 16.0 / 9.0) -> CGSize {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
              availableSize.width > 0, availableSize.height > 0 else { return .zero }
        guard fillsFrame else { return availableSize }
        let ratio = aspectRatio.isFinite && (0.125...8).contains(aspectRatio) ? aspectRatio : 16.0 / 9.0
        let width = max(availableSize.width, availableSize.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}
