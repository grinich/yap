import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Meeting fixture isolation") @MainActor
struct MeetingFixtureTests {
    @Test func receivedShareFixtureRequiresAnActivePreview() async {
        let suite = "MeetingFixtureTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = YapModel(preview: true, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
        model.showReceivedShareFixture()
        #expect(model.meeting.receivedShares.isEmpty)
        #expect(!model.activeCall)
        await model.hostMeeting()
        model.showReceivedShareFixture()
        #expect(model.meeting.receivedShares.count == 2)
        #expect(model.meeting.selectedReceivedShareID == "demo-received-landscape")
        model.stopReceivedShareFixture()
        #expect(model.meeting.receivedShares.isEmpty)
        #expect(model.activeCall)
        await model.leaveMeeting()
        model.showReceivedShareFixture()
        #expect(model.meeting.receivedShares.isEmpty)
    }

    @Test func fixtureActionsCannotMutateANonpreviewCoordinator() async {
        let suite = "MeetingFixtureTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        let model = YapModel(preview: false, preferences: preferences, meeting: meeting,
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
        await meeting.host(displayName: "Inert nonpreview coordinator")
        model.showReceivedShareFixture()
        #expect(meeting.receivedShares.isEmpty)
        driver.receiveFixtureScreenShares()
        #expect(meeting.receivedShares.count == 2)
        model.stopReceivedShareFixture()
        #expect(meeting.receivedShares.count == 2)
        #expect(model.meeting === meeting)
        await meeting.leave()
    }
}
