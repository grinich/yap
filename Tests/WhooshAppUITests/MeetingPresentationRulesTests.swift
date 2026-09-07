import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Meeting source and invitation safety")
struct MeetingPresentationRulesTests {
    @Test func hdPreferenceDoesNotInventOutgoingVideoMeasurements() {
        let preference = MeetingPresentationRules.videoQualityDescription(MeetingVideoQuality(requestsHD: true))
        #expect(preference == "HD preferred")
        #expect(!preference.contains("Sending"))
        #expect(!MeetingPresentationRules.videoQualityDescription(nil).contains("Sending"))
    }

    @Test func observedVideoDimensionsRemainVisibleBelowHd() {
        let quality = MeetingVideoQuality(requestsHD: true, sendWidth: 640, sendHeight: 360, sendFPS: 30)
        #expect(MeetingPresentationRules.videoQualityDescription(quality) == "HD preferred · Sending 640 × 360 at 30 fps")
        let missingSample = MeetingVideoQuality(requestsHD: true, sendWidth: 640, sendHeight: 0, sendFPS: 30)
        #expect(!MeetingPresentationRules.videoQualityDescription(missingSample).contains("Sending"))
    }

    @Test func liveChooserCannotOfferPreviewContent() {
        let snapshot = MeetingShareSourceSnapshot(sessionID: UUID(), targets: [
            ShareTarget(id: "preview", title: "Sample", kind: .demo),
            ShareTarget(id: "1", title: "Display", kind: .display),
            ShareTarget(id: "1", title: "Window", kind: .window)
        ], isDemo: false)
        #expect(snapshot.targets.map(\.pickerID) == ["display:1", "window:1"])
    }

    @Test func combinedSourcesPutEveryDisplayBeforeWindowsWithoutChoosingOne() {
        let sessionID = UUID()
        let snapshot = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [
            ShareTarget(id: "1", title: "A document", kind: .window),
            ShareTarget(id: "2", title: "Studio Display", kind: .display),
            ShareTarget(id: "1", title: "Built-in Retina Display", kind: .display),
            ShareTarget(id: "2", title: "Browser", kind: .window)
        ], isDemo: false)
        #expect(snapshot.presentationTargets.map(\.pickerID) == ["display:1", "display:2", "window:1", "window:2"])
        #expect(snapshot.presentationTargets.map(\.title) == ["Full display · Built-in Retina Display", "Full display · Studio Display", "A document", "Browser"])
        #expect(snapshot.target(for: nil, currentSessionID: sessionID) == nil)
    }

    @Test func singleDisplayLabelDoesNotReplaceTheOriginalShareTarget() throws {
        let sessionID = UUID()
        let display = ShareTarget(id: "7", title: "Built-in Retina Display", kind: .display)
        let snapshot = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [display], isDemo: false)
        let tile = try #require(snapshot.presentationTargets.first)
        #expect(tile.title == "Full display")
        #expect(snapshot.target(for: tile.pickerID, currentSessionID: sessionID) == display)
        #expect(snapshot.target(for: nil, currentSessionID: sessionID) == nil)
    }

    @Test func refreshedOrderingAndDisplayLabelsPreserveTheSelectedSource() throws {
        let sessionID = UUID()
        let window = ShareTarget(id: "7", title: "Document", kind: .window)
        let display = ShareTarget(id: "7", title: "Built-in Retina Display", kind: .display)
        let initial = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [window, display], isDemo: false)
        let refreshed = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [
            ShareTarget(id: "9", title: "External display", kind: .display), window, display,
            ShareTarget(id: "3", title: "A new window", kind: .window)
        ], isDemo: false)
        #expect(initial.presentationTargets.first?.title == "Full display")
        #expect(refreshed.presentationTargets.first?.title == "Full display · Built-in Retina Display")
        #expect(initial.target(for: window.pickerID, currentSessionID: sessionID) == window)
        #expect(refreshed.target(for: window.pickerID, currentSessionID: sessionID) == window)
        #expect(refreshed.target(for: display.pickerID, currentSessionID: sessionID) == display)
        let removed = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [display], isDemo: false)
        #expect(removed.target(for: window.pickerID, currentSessionID: sessionID) == nil)
    }

    @Test func unnamedDisplaysRemainDistinctAndWindowNamesStayUnchanged() {
        let window = ShareTarget(id: "w", title: "  Untitled document  ", kind: .window)
        let snapshot = MeetingShareSourceSnapshot(sessionID: UUID(), targets: [
            window,
            ShareTarget(id: "2", title: "", kind: .display),
            ShareTarget(id: "1", title: "", kind: .display)
        ], isDemo: false)
        #expect(snapshot.presentationTargets.map(\.title) == ["Full display · Display 1", "Full display · Display 2", window.title])
        #expect(snapshot.presentationTargets.last == window)
        #expect(Set(snapshot.presentationTargets.map(\.pickerID)).count == 3)
    }

    @Test func previewChooserCannotOfferLiveContent() {
        let snapshot = MeetingShareSourceSnapshot(sessionID: UUID(), targets: [
            ShareTarget(id: "sample", title: "Sample", kind: .demo),
            ShareTarget(id: "42", title: "Private document", kind: .window)
        ], isDemo: true)
        #expect(snapshot.targets.map(\.pickerID) == ["demo:sample"])
    }

    @Test func selectionsDoNotSurviveSessionReplacementOrSourceRemoval() {
        let sessionID = UUID()
        let source = ShareTarget(id: "42", title: "Document", kind: .window)
        let original = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [source], isDemo: false)
        #expect(original.target(for: source.pickerID, currentSessionID: sessionID) == source)
        #expect(original.target(for: source.pickerID, currentSessionID: UUID()) == nil)
        #expect(original.target(for: source.pickerID, currentSessionID: nil) == nil)
        let refreshed = MeetingShareSourceSnapshot(sessionID: sessionID, targets: [], isDemo: false)
        #expect(refreshed.target(for: source.pickerID, currentSessionID: sessionID) == nil)
    }

    @Test func duplicateSourceIDsDoNotProduceAmbiguousSelections() {
        let source = ShareTarget(id: "42", title: "Document", kind: .window)
        let snapshot = MeetingShareSourceSnapshot(sessionID: UUID(), targets: [source, source, ShareTarget(id: "", title: "Invalid", kind: .window)], isDemo: false)
        #expect(snapshot.targets == [source])
    }

    @Test func onlyCurrentLiveZoomInvitationsCanBeCopied() {
        let url = URL(string: "https://example.zoom.us/j/123456789?pwd=invitation-token")!
        #expect(MeetingPresentationRules.invitationToCopy(url, isConnected: true, isDemo: false) == url)
        #expect(MeetingPresentationRules.invitationToCopy(url, isConnected: false, isDemo: false) == nil)
        #expect(MeetingPresentationRules.invitationToCopy(url, isConnected: true, isDemo: true) == nil)
        #expect(MeetingPresentationRules.invitationToCopy(nil, isConnected: true, isDemo: false) == nil)
        for invalid in ["http://zoom.us/j/123", "https://zoom.us.example.com/j/123", "https://someone:secret@zoom.us/j/123"] {
            #expect(MeetingPresentationRules.invitationToCopy(URL(string: invalid), isConnected: true, isDemo: false) == nil)
        }
    }
}
