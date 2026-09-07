import Foundation
import Testing
@testable import WhooshAppUI

@Suite("Incoming URL delivery") @MainActor
struct WhooshIncomingURLRouterTests {
    private let first = URL(string: "zoommtg://zoom.us/join?action=join&confno=12345678901")!
    private let second = URL(string: "zoommtg://zoom.us/join?action=join&confno=98765432101")!

    @Test func coldLaunchRetainsLatestInvitationAndDeliversItOnceWhenWindowAttaches() {
        let router = WhooshIncomingURLRouter()
        var opened: [URL] = []
        router.receive([first])
        router.receive([second])
        router.receive([])
        router.configure { opened.append($0) }
        router.configure { opened.append($0) }
        #expect(opened == [second])
    }

    @Test func warmDeliveryRevealsTheMainWindowForEachIncomingInvitation() {
        let router = WhooshIncomingURLRouter()
        var opened: [URL] = []
        var revealCount = 0
        router.configure { opened.append($0); revealCount += 1 }
        router.receive([first])
        router.receive([first, second])
        #expect(opened == [first, second])
        #expect(revealCount == 2)
    }
}
