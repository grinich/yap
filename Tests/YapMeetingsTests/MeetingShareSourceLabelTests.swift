import Testing
@testable import YapMeetings

@Suite("Confirmed sharing source labels")
struct MeetingShareSourceLabelTests {
    private let windowA = ShareTarget(id: "41", title: "Test window A", kind: .window)
    private let windowB = ShareTarget(id: "42", title: "Test window B", kind: .window)
    private let display = ShareTarget(id: "42", title: "Test display", kind: .display)

    @Test func missingSDKIdentifiersNeverReuseASelectedWindowLabel() {
        let result = MeetingShareSourceLabel.target(windowID: 0, displayID: 0, available: [windowA, windowB])
        #expect(result.title == "Shared screen")
        #expect(result != windowA && result != windowB)
    }

    @Test func onlyConfirmedWindowIDsIdentifyTheSwitchedSource() {
        let available = [windowA, windowB, display]
        #expect(MeetingShareSourceLabel.target(windowID: 41, displayID: 0, available: available) == windowA)
        #expect(MeetingShareSourceLabel.target(windowID: 42, displayID: 0, available: available) == windowB)
    }

    @Test func displayAndWindowIdentifiersDoNotCollide() {
        #expect(MeetingShareSourceLabel.target(windowID: 0, displayID: 42, available: [windowB, display]) == display)
        #expect(MeetingShareSourceLabel.target(windowID: 42, displayID: 42, available: [display, windowB]) == windowB)
    }

    @Test func unavailableSourceNamesRemainGeneric() {
        let window = MeetingShareSourceLabel.target(windowID: 99, displayID: 0, available: [windowA])
        #expect(window.id == "99" && window.kind == .window && window.title == "Shared window")
        let display = MeetingShareSourceLabel.target(windowID: 0, displayID: 99, available: [windowA])
        #expect(display.id == "99" && display.kind == .display && display.title == "Shared display")
    }
}
