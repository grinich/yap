import AppKit
import Testing
@testable import YapAppUI

@Suite("Corner self-view and window levels", .serialized) @MainActor
struct MeetingCornerTests {
    @Test func cornersStayInsideAndSnapBackToTheirOwnPosition() {
        for size in [CGSize(width: 320, height: 300), CGSize(width: 900, height: 620)] {
            for corner in MeetingSelfViewLayout.Corner.allCases {
                let frame = MeetingSelfViewLayout.frame(in: size, aspectRatio: 16.0 / 9,
                                                       compactHeight: size.height < 420, corner: corner)
                #expect(CGRect(origin: .zero, size: size).contains(frame))
                #expect(MeetingSelfViewLayout.nearestCorner(to: CGPoint(x: frame.midX, y: frame.midY), in: size) == corner)
                #expect(frame.maxY <= size.height - 90)
            }
        }
    }

    @Test func keepOnTopUpdatesExistingAndNewWindowsAndCanBeTurnedOff() {
        let state = YapWindowLevel()
        let first = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        state.register(first)
        #expect(first.level == .normal)
        state.isEnabled = true
        #expect(first.level == .floating)
        state.register(second)
        #expect(second.level == .floating)
        state.isEnabled = false
        #expect(first.level == .normal && second.level == .normal)
    }
}
