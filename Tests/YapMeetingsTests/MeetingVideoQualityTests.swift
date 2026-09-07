import Foundation
import Testing
@testable import YapMeetings

@Suite("Observed camera quality") @MainActor
struct MeetingVideoQualityTests {
    @Test func preferenceDoesNotInventSentResolution() {
        let preferred = MeetingVideoQuality(requestsHD: true)
        #expect(preferred.sendWidth == nil)
        #expect(preferred.sendHeight == nil)
        #expect(preferred.sendFPS == nil)
        let noVideo = MeetingVideoQuality(requestsHD: true, sendWidth: 0, sendHeight: 720, sendFPS: 30)
        #expect(noVideo.sendWidth == nil && noVideo.sendHeight == nil && noVideo.sendFPS == nil)
    }

    @Test func observedQualityCannotLeakAcrossMeetings() async {
        let driver = DemoMeetingDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Test")
        let oldID = meeting.sessionID!
        let actual = MeetingVideoQuality(requestsHD: true, sendWidth: 640, sendHeight: 360, sendFPS: 24)
        driver.onEvent?(oldID, .videoQuality(actual))
        #expect(meeting.videoQuality == actual)
        await meeting.leave()
        #expect(meeting.videoQuality == nil)
        await meeting.host(displayName: "Test")
        driver.onEvent?(oldID, .videoQuality(actual))
        #expect(meeting.videoQuality == nil)
        await meeting.leave()
    }
}
