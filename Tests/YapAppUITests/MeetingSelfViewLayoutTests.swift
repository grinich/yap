import CoreGraphics
import Testing
@testable import YapAppUI

@Suite("Self-view overlay layout")
struct MeetingSelfViewLayoutTests {
    @Test func staysSmallAndClearOfControlsAtSupportedWindowSizes() {
        for size in [CGSize(width: 320, height: 300), CGSize(width: 320, height: 750),
                     CGSize(width: 640, height: 360), CGSize(width: 960, height: 680), CGSize(width: 1800, height: 1000)] {
            for ratio in [16.0 / 9.0, 9.0 / 16.0, 1.0] {
                let frame = MeetingSelfViewLayout.frame(in: size, aspectRatio: ratio, compactHeight: size.height < 420)
                #expect(frame.width > 0 && frame.height > 0)
                #expect(frame.width <= 180 && frame.height <= 144)
                #expect(frame.minY >= 54 && frame.maxY <= size.height - 90)
                #expect(frame.maxX < size.width && frame.minX > 0)
                #expect(abs(frame.width / frame.height - ratio) < 0.000_001)
            }
        }
    }
    @Test func unusableGeometryAndRatiosAreSafe() {
        #expect(MeetingSelfViewLayout.frame(in: .zero, aspectRatio: 1, compactHeight: true) == .zero)
        let size = CGSize(width: 320, height: 300)
        for ratio in [Double.nan, .infinity, 0, -1] {
            let frame = MeetingSelfViewLayout.frame(in: size, aspectRatio: ratio, compactHeight: true)
            #expect(frame.width.isFinite && frame.height.isFinite)
        }
    }
}
