import SwiftUI
import Testing
@testable import YapAppUI

@Suite("Gallery drop targets")
struct GalleryDropTargetTests {
    @Test func findsPortraitAndLandscapeTilesAtDifferentWindowSizes() {
        for size in [CGSize(width: 320, height: 750), CGSize(width: 960, height: 680)] {
            let frames = MeetingTileArrangement.frames(aspectRatios: [16 / 9, 9 / 16, 16 / 9], size: size, spacing: 10)
            for (index, frame) in frames.enumerated() {
                #expect(MeetingGalleryDropTarget.index(at: CGPoint(x: frame.midX, y: frame.midY), frames: frames) == index)
            }
        }
    }
    @Test func outsideAndEmptyDropsDoNotChooseAParticipant() {
        let frames = [CGRect(x: 10, y: 20, width: 100, height: 100), CGRect(x: 120, y: 20, width: 60, height: 100)]
        for point in [CGPoint.zero, CGPoint(x: 115, y: 60), CGPoint(x: 150, y: 160), CGPoint(x: CGFloat.nan, y: 10)] {
            #expect(MeetingGalleryDropTarget.index(at: point, frames: frames) == nil)
        }
        #expect(MeetingGalleryDropTarget.index(at: .zero, frames: [.zero]) == nil)
        #expect(MeetingGalleryDropTarget.index(at: .zero, frames: []) == nil)
    }
}
