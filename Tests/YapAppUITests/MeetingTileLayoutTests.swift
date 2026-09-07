import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Video aspect ratios and gallery layout")
struct MeetingTileLayoutTests {
    @Test func phoneVideoKeepsItsPortraitShapeAndUsesTallWindow() {
        let frames = MeetingTileArrangement.frames(aspectRatios: [16 / 9, 9 / 16],
                                                   size: CGSize(width: 308, height: 736), spacing: 10)
        #expect(frames.count == 2)
        #expect(abs(frames[0].width / frames[0].height - 16 / 9) < 0.001)
        #expect(abs(frames[1].width / frames[1].height - 9 / 16) < 0.001)
        #expect(frames[1].width > 300)
        #expect(frames[1].height > 530)
        #expect(frames[0].maxY + 9.99 <= frames[1].minY)
    }

    @Test func mixedGridsStayInsideTheirCanvasWithoutOverlap() {
        for count in [1, 2, 3, 9, 25, 49, 100, 101] {
            for size in [CGSize(width: 320, height: 240), CGSize(width: 320, height: 750),
                         CGSize(width: 1440, height: 900)] {
                let formats: [Double] = [16 / 9, 9 / 16, 1, 4 / 3]
                let ratios = (0..<count).map { formats[$0 % formats.count] }
                let frames = MeetingTileArrangement.frames(aspectRatios: ratios, size: size, spacing: 6)
                #expect(frames.count == count)
                for (index, frame) in frames.enumerated() {
                    #expect(frame.minX >= -0.001 && frame.minY >= -0.001)
                    #expect(frame.maxX <= size.width + 0.001 && frame.maxY <= size.height + 0.001)
                    #expect(frame.width > 0 && frame.height > 0)
                    #expect(abs(frame.width / frame.height - ratios[index]) < 0.001)
                    for other in frames.dropFirst(index + 1) {
                        #expect(!frame.insetBy(dx: 0.001, dy: 0.001).intersects(other))
                    }
                }
            }
        }
    }

    @Test func landscapeGridsKeepUniformTilesIncludingIncompleteRows() {
        let frames = MeetingTileArrangement.frames(aspectRatios: Array(repeating: 16 / 9, count: 7),
                                                   size: CGSize(width: 900, height: 600), spacing: 10)
        #expect(frames.allSatisfy { abs($0.width - frames[0].width) < 0.001 && abs($0.height - frames[0].height) < 0.001 })
    }

    @Test func invalidOrTransitionalGeometryDoesNotEscapeBounds() {
        #expect(MeetingTileArrangement.frames(aspectRatios: [], size: .zero, spacing: 10).isEmpty)
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: CGFloat.infinity, height: 500)] {
            let frames = MeetingTileArrangement.frames(aspectRatios: [0, .nan, .infinity], size: size, spacing: 10)
            #expect(frames.allSatisfy { $0 == .zero })
        }
        let frames = MeetingTileArrangement.frames(aspectRatios: [.nan, -1], size: CGSize(width: 800, height: 600), spacing: 10)
        #expect(frames.allSatisfy { abs($0.width / $0.height - 16 / 9) < 0.001 })
    }

    @Test func dimensionsValidateAndCameraOffReturnsToAvatarShape() {
        #expect(MeetingVideoSize(width: 0, height: 720) == nil)
        #expect(MeetingVideoSize(width: .nan, height: 720) == nil)
        #expect(MeetingVideoSize(width: 720, height: .infinity) == nil)
        #expect(MeetingVideoSize(width: 1, height: 16000) == nil)
        var person = MeetingParticipant(id: "phone", name: "Phone", isCameraEnabled: true,
                                        videoSize: MeetingVideoSize(width: 720, height: 1280))
        #expect(person.tileAspectRatio == 9.0 / 16.0)
        person.videoSize = MeetingVideoSize(width: 1280, height: 720)
        #expect(person.tileAspectRatio == 16.0 / 9.0)
        person.videoSize = MeetingVideoSize(width: 720, height: 1280)
        person.isCameraEnabled = false
        #expect(person.tileAspectRatio == 16.0 / 9.0)
    }
}
