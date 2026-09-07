import Foundation
import Testing
@testable import WhooshUpdates

@Suite struct UpdateSafetyTests {
    private var key: String { Data(repeating: 1, count: 32).base64EncodedString() }

    @Test func requiresHTTPSAndSigningKey() {
        #expect(UpdateConfiguration(info: [:]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/appcast.xml"]) == nil)
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/feed", "https://"] {
            #expect(UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": key]) == nil)
        }
        for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": key]) == nil)
        }
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": key]) != nil)
    }

    @MainActor @Test func blocksUpdatesForEntireCall() {
        var active = true
        let gate = MeetingUpdateGate(isMeetingActive: { active })
        #expect(!gate.canInstall)
        active = false
        #expect(gate.canInstall)
    }

    @MainActor @Test func rechecksMeetingAtInstallTime() {
        var active = false
        let gate = MeetingUpdateGate(isMeetingActive: { active })
        #expect(gate.canInstall)
        active = true // Meeting started while the update was downloading.
        #expect(!gate.canInstall)
        active = false
        #expect(gate.canInstall)
    }
}
