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

    @Test func topCornersMoveClearOfToolbarWithoutResizingOrShiftingSideways() {
        for size in [CGSize(width: 320, height: 300), CGSize(width: 900, height: 620)] {
            for ratio in [16.0 / 9, 9.0 / 16, 1.0] {
                for corner in MeetingSelfViewLayout.Corner.allCases {
                    let hidden = MeetingSelfViewLayout.frame(in: size, aspectRatio: ratio,
                        compactHeight: size.height < 420, corner: corner, showsControls: false)
                    let visible = MeetingSelfViewLayout.frame(in: size, aspectRatio: ratio,
                        compactHeight: size.height < 420, corner: corner, showsControls: true)
                    #expect(hidden.size == visible.size)
                    #expect(hidden.minX == visible.minX)
                    #expect(CGRect(origin: .zero, size: size).contains(hidden))
                    if corner == .topLeft || corner == .topRight {
                        #expect(hidden.minY == min(16, size.width * 0.04))
                        #expect(visible.minY >= 54)
                        #expect(visible.minY > hidden.minY)
                    } else {
                        #expect(hidden == visible)
                    }
                }
            }
        }
    }

    @Test func pinButtonTogglesTheWindowLevelAndTracksMenuChanges() async throws {
        let level = YapWindowLevel()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        level.register(window)
        let button = YapWindowPinButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24), windowLevel: level)
        #expect(button.toolTip == "Keep on Top")
        #expect(button.state == .off)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(!button.mouseDownCanMoveWindow)
        button.performClick(nil)
        #expect(window.level == .floating && button.state == .on)
        button.performClick(nil)
        #expect(window.level == .normal && button.state == .off)
        // The View menu changes this same setting without clicking the button.
        level.isEnabled = true
        for _ in 0..<20 where button.state != .on { try await Task.sleep(for: .milliseconds(5)) }
        #expect(button.state == .on)
        level.isEnabled = false
        for _ in 0..<20 where button.state != .off { try await Task.sleep(for: .milliseconds(5)) }
        #expect(button.state == .off)
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
