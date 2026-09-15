import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Media menu command intent") @MainActor
struct MeetingMediaTestMenuActionTests {
    @Test(arguments: [MeetingMediaKind.microphone, .speaker])
    func displayedStopCannotStartAgainAfterTestEnds(kind: MeetingMediaKind) async {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        defer { meeting.stopMediaTests() }
        await meeting.prepareMediaDevices()
        await meeting.setMediaTest(kind, running: true)
        let menuAction = MeetingMediaTestMenuAction(kind: kind, isTesting: isTesting(meeting, kind: kind))
        #expect(menuAction.title == "Stop \(kind.rawValue) test")

        // Reproduce the timeout occurring while the native menu stays open.
        driver.stopMediaTests()
        #expect(!isTesting(meeting, kind: kind))
        await menuAction.perform(on: meeting)

        #expect(!isTesting(meeting, kind: kind))
        #expect(!menuAction.isStarting)
    }

    @Test(arguments: [MeetingMediaKind.microphone, .speaker])
    func displayedStartCannotTurnIntoStopAfterStateChanges(kind: MeetingMediaKind) async {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        defer { meeting.stopMediaTests() }
        await meeting.prepareMediaDevices()
        let menuAction = MeetingMediaTestMenuAction(kind: kind, isTesting: isTesting(meeting, kind: kind))

        await meeting.setMediaTest(kind, running: true)
        #expect(isTesting(meeting, kind: kind))
        await menuAction.perform(on: meeting)

        #expect(isTesting(meeting, kind: kind))
        #expect(menuAction.isStarting)
    }

    private func isTesting(_ meeting: MeetingCoordinator, kind: MeetingMediaKind) -> Bool {
        kind == .microphone ? meeting.mediaDevices.microphoneTest != "idle" : meeting.mediaDevices.speakerTestRunning
    }
}
