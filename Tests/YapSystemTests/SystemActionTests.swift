import Foundation
import Testing
@testable import YapSystem

struct SystemActionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func incomingInvitationSupersedesQueuedCalendarActionsDuringStartup() {
        var queue = PendingSystemActions()
        queue.enqueue(.openYap, now: now)
        queue.enqueue(.joinNextMeeting, now: now)
        queue.enqueue(.showMeeting(id: "older-invitation"), now: now)
        queue.enqueue(.showUpcomingMeetings, now: now)
        queue.discardMeetingNavigation()
        #expect(queue.take(now: now) == .openYap)
        #expect(queue.take(now: now) == .showUpcomingMeetings)
        #expect(queue.take(now: now) == nil)
    }

    @Test func explicitlyRequestedMeetingAfterIncomingURLRemainsAvailable() {
        var queue = PendingSystemActions()
        queue.enqueue(.joinNextMeeting, now: now)
        queue.discardMeetingNavigation()
        queue.enqueue(.showMeeting(id: "new-choice"), now: now)
        #expect(queue.take(now: now) == .showMeeting(id: "new-choice"))
        #expect(queue.take(now: now) == nil)
    }

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
        queue.enqueue(.openYap, now: now)
        queue.enqueue(.showMeeting(id: "current-calendar-event"), now: now)
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == .openYap)
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == .showMeeting(id: "current-calendar-event"))
        #expect(queue.take(now: now.addingTimeInterval(3_600)) == nil)
    }
}
