import Foundation
import Testing
@testable import WhooshCalendar

@Suite("Native Zoom meeting invitations")
struct ZoomNativeMeetingLinkTests {
    @Test(arguments: ["zoommtg", "zoomus", "ZOOMMTG"])
    func normalizesJoinAndPreservesOpaquePasscode(_ scheme: String) {
        let passcode = "abc%2Bdef+ghi%2fjkl%3D%26another%3Dvalue%252B"
        let native = "\(scheme)://US02WEB.ZOOM.US/join?action=join&confno=01234567890&pwd=\(passcode)"
        let result = ZoomMeetingLinkParser.normalizedJoinURL(native)
        #expect(result?.absoluteString == "https://us02web.zoom.us/j/01234567890?pwd=\(passcode)")
        #expect(result.flatMap { ZoomMeetingLinkParser.validatedURL($0.absoluteString) } == result)
    }

    @Test func discardsLauncherMetadataWithoutApplyingOverrides() {
        let native = "zoommtg://zoom.us/join?action=join&confno=123456789&pwd=stay&zc=0&uname=Some%20Name&video=1&audio=1&browser=chrome&future_option=on&sid=user&uid=user"
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(native)?.absoluteString == "https://zoom.us/j/123456789?pwd=stay")
    }

    @Test func acceptsExplicitJoinPathsAndOptionalPasscodes() {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoomus://tenant.zoom.com/j/12345678901")?.absoluteString == "https://tenant.zoom.com/j/12345678901")
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us:443/j/123456789?action=join&pwd=")?.absoluteString == "https://zoom.us/j/123456789?pwd=")
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/join?action=join&confno=123456789")?.absoluteString == "https://zoom.us/j/123456789")
    }

    @Test func leavesExistingHTTPSInvitationBehaviorIntact() {
        let https = "https://us02web.zoom.us/s/12345678901?pwd=abc%2Bdef&omn=93455#details"
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(https)?.absoluteString == https)
        #expect(ZoomMeetingLinkParser.validatedURL("zoommtg://zoom.us/join?action=join&confno=123456789") == nil)
        #expect(ZoomMeetingLinkParser.links(in: "zoommtg://zoom.us/join?action=join&confno=123456789").isEmpty)
    }

    @Test(arguments: [
        "zoommtg://zoom.us/start?action=join&confno=123456789", "zoomus://zoom.us/signin?token=secret",
        "zoommtg://zoom.us/join?action=start&confno=123456789", "zoommtg://zoom.us/join?action=host&confno=123456789",
        "zoommtg://zoom.us/join?action=auth&confno=123456789", "zoommtg://zoom.us/join?confno=123456789",
        "zoommtg://zoom.us/j/123456789?action=start", "zoommtg://zoom.us/s/123456789", "zoommtg://zoom.us/my/person",
        "zoommtg://zoom.us/j/123456789?confno=123456789", "zoommtg://zoom.us/j/123456789?confno=987654321"
    ])
    func rejectsUnsupportedOrAmbiguousActions(_ input: String) {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(input) == nil)
    }

    @Test(arguments: ["zak", "ZAK", "%7Aak", "tk", "token", "jwt", "auth", "access_token", "host_key", "role"])
    func rejectsAuthorityTokensInsteadOfDowngradingTheJoin(_ key: String) {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/join?action=join&confno=123456789&\(key)=secret") == nil)
    }

    @Test func rejectsHostStartTypeButDiscardsOrdinaryClientType() {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/join?action=join&confno=123456789&stype=100") == nil)
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/join?action=join&confno=123456789&stype=99")?.absoluteString == "https://zoom.us/j/123456789")
    }

    @Test(arguments: [
        "zoommtg://zoom.us.evil.test/j/123456789", "zoommtg://notzoom.us/j/123456789", "zoommtg://zoom.us@evil.test/j/123456789",
        "zoommtg://user@zoom.us/j/123456789", "zoommtg://user:pass@zoom.us/j/123456789", "zoommtg://zoom.us:444/j/123456789",
        "zoommtg://zoom.us./j/123456789", "zoommtg://.zoom.us/j/123456789", "zoommtg://bad..zoom.us/j/123456789",
        "zoommtg://-bad.zoom.us/j/123456789", "zoommtg://%7Aoom.us/j/123456789", "zoommtg://zoom.us/j/123456789#fragment",
        "zoommtg://zoom.us/j/%31%32%33%34%35%36%37%38%39", "zoommtg://zoom.us/j/123456789/extra",
        "zoommtg://zoom.us/j/12345678", "zoommtg://zoom.us/j/123456789012", "zoommtg://zoom.us/j/000000000",
        "zoommtg://zoom.us/j/１２３４５６７８９", "zoommtg://zoom.us//j/123456789", "zoommtg:zoom.us/j/123456789",
        "http://zoom.us/j/123456789", "javascript:alert(1)"
    ])
    func rejectsSpoofedAuthoritiesAndMalformedMeetingPaths(_ input: String) {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(input) == nil)
    }

    @Test(arguments: [
        "action=join&confno=123456789&confno=987654321", "action=join&confno=123456789&%63onfno=123456789",
        "action=join&confno=123456789&CONFNO=123456789", "action=join&action=start&confno=123456789",
        "action=join&confno=123456789&pwd=one&PWD=two", "action=join&confno=123456789&zc=0&zc=1",
        "action=join&confno=123456789&pwd", "action=join&confno=123456789&=value", "action=join&confno=123456789&",
        "action=join&&confno=123456789", "action=join&confno=%31%32%33%34%35%36%37%38%39",
        "action=join&confno=123456789&pwd=%", "action=join&confno=123456789&pwd=%GG", "action=join&confno=123456789&pwd=%FF",
        "action=join&confno=123456789&pwd=raw space", "action=join&confno=123456789&pwd=%00secret",
        "action=join&confno=123456789&metadata=%0D%0A", "action=join&confno=123456789&pwd=secret\n"
    ])
    func rejectsDuplicateOrMalformedParameters(_ query: String) {
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/join?" + query) == nil)
    }

    @Test func boundsInputAndParameterWork() {
        let base = "zoommtg://zoom.us/join?action=join&confno=123456789&pwd="
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(base + String(repeating: "a", count: 8_192)) != nil)
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(base + String(repeating: "a", count: 8_193)) == nil)
        #expect(ZoomMeetingLinkParser.normalizedJoinURL(base + String(repeating: "%61", count: 6_000)) == nil)
        let tooMany = (0..<65).map { "extra\($0)=value" }.joined(separator: "&")
        #expect(ZoomMeetingLinkParser.normalizedJoinURL("zoommtg://zoom.us/j/123456789?" + tooMany) == nil)
    }
}
