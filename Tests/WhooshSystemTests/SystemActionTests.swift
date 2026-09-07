import Foundation
import Testing
@testable import WhooshSystem

struct SystemActionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshExplicitJoinSurvivesColdStart() {
        var queue = PendingSystemActions()
        queue.enqueue(.joinNextMeeting, now: now)
        #expect(queue.take(now: now.addingTimeInterval(20)) == .joinNextMeeting)
        #expect(queue.take(now: now.addingTimeInterval(21)) == nil)
    }

    @Test func staleJoinOpensAgendaInsteadOfJoiningAnUnrelatedMeeting() {
        var queue = PendingSystemActions()
        queue.enqueue(.joinNextMeeting, now: now)
        #expect(queue.take(now: now.addingTimeInterval(61)) == .showUpcomingMeetings)
    }

    @Test func clockMovingBackwardDoesNotReplayAJoin() {
        var queue = PendingSystemActions()
        queue.enqueue(.joinNextMeeting, now: now)
        #expect(queue.take(now: now.addingTimeInterval(-1)) == .showUpcomingMeetings)
    }

    @Test func navigationRequestsRemainOrderedWithoutGainingJoinAuthority() {
        var queue = PendingSystemActions()
        queue.enqueue(.openWhoosh, now: now)
        queue.enqueue(.showMeeting(id: "current-calendar-event"), now: now)
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == .openWhoosh)
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == .showMeeting(id: "current-calendar-event"))
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == nil)
    }
}
