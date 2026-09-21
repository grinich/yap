import AppKit
import Testing
@testable import YapMeetings

@Suite("Local received-share preview") @MainActor
struct DemoReceivedShareTests {
    @Test func receivingTheFixtureIsExplicitAndDoesNotEnableOutgoingMedia() async {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        #expect(meeting.capabilities.canReceiveShare)
        driver.receiveFixtureScreenShares()
        #expect(meeting.receivedShares.isEmpty)

        await meeting.host(displayName: "Preview")
        #expect(meeting.receivedShares.isEmpty)
        driver.receiveFixtureScreenShares()

        #expect(meeting.receivedShares.map(\.id) == ["demo-received-landscape", "demo-received-portrait"])
        #expect(meeting.selectedReceivedShareID == "demo-received-landscape")
        #expect(meeting.receivedShares.allSatisfy { $0.title.contains("local preview") })
        #expect(meeting.isMicrophoneMuted)
        #expect(!meeting.isCameraEnabled)
        #expect(!meeting.sharing.isSharing)
        #expect(meeting.cloudRecording.status == .stopped)
        await meeting.leave()
    }

    @Test func switchingAndHidingSourcesUsesTheProductionSelectionAndOneRendererPerSource() async throws {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Preview")
        driver.receiveFixtureScreenShares()
        let landscapeID = "demo-received-landscape", portraitID = "demo-received-portrait"
        let landscape = try #require(meeting.nativeShareView(for: landscapeID))
        #expect(landscape.intrinsicContentSize == NSSize(width: 1600, height: 1000))
        #expect(meeting.nativeShareView(for: landscapeID) === landscape)
        #expect(meeting.nativeShareView(for: portraitID) == nil)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        host.addSubview(landscape)

        meeting.selectReceivedShare(portraitID)
        let portrait = try #require(meeting.nativeShareView(for: portraitID))
        #expect(portrait.intrinsicContentSize == NSSize(width: 1000, height: 1600))
        #expect(landscape.superview == nil)
        #expect(meeting.nativeShareView(for: landscapeID) == nil)
        host.addSubview(portrait)
        meeting.toggleSharedContent()
        #expect(meeting.selectedReceivedShare == nil)
        #expect(portrait.superview == nil)
        meeting.toggleSharedContent()
        #expect(meeting.selectedReceivedShareID == portraitID)
        #expect(meeting.nativeShareView(for: portraitID) === portrait)
        meeting.selectReceivedShare(landscapeID)
        #expect(meeting.nativeShareView(for: landscapeID) === landscape)
        await meeting.leave()
    }

    @Test func stoppingAndLeavingDetachRenderersAndNeverCarrySharingIntoTheNextSession() async throws {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Preview")
        driver.receiveFixtureScreenShares()
        let sourceID = "demo-received-landscape"
        let original = try #require(meeting.nativeShareView(for: sourceID))
        let host = NSView(frame: original.frame)
        host.addSubview(original)

        driver.stopFixtureScreenShares()
        #expect(meeting.receivedShares.isEmpty)
        #expect(meeting.selectedReceivedShareID == nil)
        #expect(driver.nativeShareView(for: sourceID) == nil)
        #expect(original.superview == nil)
        #expect(meeting.isConnected)

        driver.receiveFixtureScreenShares()
        let replacement = try #require(meeting.nativeShareView(for: sourceID))
        #expect(replacement !== original)
        host.addSubview(replacement)
        await meeting.leave()
        #expect(replacement.superview == nil)
        #expect(meeting.receivedShares.isEmpty)
        #expect(driver.nativeShareView(for: sourceID) == nil)
        driver.receiveFixtureScreenShares()
        #expect(meeting.receivedShares.isEmpty)
        await meeting.host(displayName: "Next preview")
        #expect(meeting.receivedShares.isEmpty)
        #expect(meeting.selectedReceivedShareID == nil)
        await meeting.leave()
    }
}
