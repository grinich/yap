import CoreGraphics
import Testing
@testable import WhooshAppUI

@MainActor
struct NativeVideoFillTests {
    @Test(arguments: [CGSize(width: 860, height: 700), CGSize(width: 1_600, height: 600),
                      CGSize(width: 320, height: 180), CGSize(width: 350, height: 700)])
    func fillingCoversTheFrameWithoutDistortingTheCanvas(_ available: CGSize) {
        let size = NativeVideoContainer.rendererSize(for: available, fillsFrame: true)
        #expect(size.width + 0.000_001 >= available.width)
        #expect(size.height + 0.000_001 >= available.height)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.000_001)
        #expect(abs(size.width - available.width) < 0.000_001 || abs(size.height - available.height) < 0.000_001)
    }

    @Test func normalAndPiPKeepTheirParentGeometry() {
        let size = CGSize(width: 112, height: 63)
        #expect(NativeVideoContainer.rendererSize(for: size, fillsFrame: false) == size)
        let arbitrary = CGSize(width: 123, height: 87)
        #expect(NativeVideoContainer.rendererSize(for: arbitrary, fillsFrame: false) == arbitrary)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 100), CGSize(width: 100, height: 0),
                      CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan)])
    func unusableProposalsNeverMountAnOversizedRenderer(_ available: CGSize) {
        #expect(NativeVideoContainer.rendererSize(for: available, fillsFrame: true) == .zero)
    }
}
