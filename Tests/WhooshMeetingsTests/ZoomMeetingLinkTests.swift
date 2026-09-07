import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Zoom invitation parsing")
struct ZoomMeetingLinkTests {
    @Test func preservesOpaqueInvitationTokensAndRedactsDescription() throws {
        let link = try ZoomMeetingLink(URL(string: "https://example.zoom.us/j/12345678901?pwd=opaque%2Btoken%3D%3D&tk=registrant")!)
        #expect(link.meetingNumber == 12_345_678_901)
        #expect(link.vanityID == nil)
        #expect(link.embeddedPasscode == "opaque+token==")
        #expect(link.registrantToken == "registrant")
        #expect(!link.description.contains("12345678901"))
        #expect(!link.debugDescription.contains("opaque"))
    }

    @Test func parsesVanityLinksWithoutInventingMeetingNumber() throws {
        let link = try ZoomMeetingLink(URL(string: "https://zoom.us/my/test.person")!)
        #expect(link.meetingNumber == 0)
        #expect(link.vanityID == "test.person")
    }

    @Test func rejectsAmbiguousOrMalformedNativeJoinParameters() {
        let invalid = [
            "https://zoom.us/j/not-a-number", "https://zoom.us/j/12345678901/extra",
            "https://zoom.us/j/12345678901?pwd=one&pwd=two", "https://zoom.us/j/12345678901?tk=one&tk=two",
            "https://zoom.us/my/name%2Fother", "https://zoom.us/j/12345678901?pwd=bad%0Avalue",
            "https://zoom.us//j/12345678901", "https://zoom.us/j/00000000000",
            "https://zoom.us.evil.example/j/12345678901", "https://user@zoom.us/j/12345678901",
            "https://zoom.us:8443/j/12345678901"
        ]
        for value in invalid {
            #expect(throws: MeetingError.invalidLink) { try ZoomMeetingLink(URL(string: value)!) }
        }
    }
}
