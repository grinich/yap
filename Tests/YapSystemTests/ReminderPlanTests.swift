import Foundation
import Testing
@testable import YapSystem

struct ReminderPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, startsIn: TimeInterval, title: String = "Meeting") -> MeetingReminder {
        MeetingReminder(
            id: id,
            title: title,
            startDate: now.addingTimeInterval(startsIn),
            meetingURL: URL(string: "https://zoom.us/j/12345678901?pwd=private")!
        )
    }

    @Test func onlyFutureDeliveryTimesAreScheduled() {
        let plan = ReminderPlan.make(
            meetings: [meeting("past", startsIn: -300), meeting("too-late", startsIn: 60), meeting("now", startsIn: 120), meeting("future", startsIn: 300)],
            now: now
        )
        #expect(plan.map(\.meeting.id) == ["future"])
        #expect(plan.first?.fireDate == now.addingTimeInterval(180))
    }

    @Test func lastCalendarSnapshotWinsForAnOccurrence() {
        let plan = ReminderPlan.make(
            meetings: [meeting("same", startsIn: 400), meeting("same", startsIn: 900, title: "Rescheduled")],
            now: now
        )
        #expect(plan.count == 1)
        #expect(plan.first?.meeting.title == "Rescheduled")
        #expect(plan.first?.fireDate == now.addingTimeInterval(780))
    }

    @Test func recurringOccurrencesRetainSeparateReminders() {
        let plan = ReminderPlan.make(meetings: [meeting("event/today", startsIn: 500), meeting("event/tomorrow", startsIn: 86_400)], now: now)
        #expect(plan.count == 2)
        #expect(Set(plan.map(\.id)).count == 2)
    }

    @Test func cancellationRemovesOnlyOwnedReminders() {
        let retained = ReminderPlan.identifier(for: "keep")
        let canceled = ReminderPlan.identifier(for: "remove")
        #expect(ReminderPlan.staleIdentifiers(existing: [retained, canceled, "another-feature"], keeping: [retained]) == [canceled])
    }

    @Test func remindersAreOrderedAndBounded() {
        let plan = ReminderPlan.make(meetings: [meeting("third", startsIn: 800), meeting("second", startsIn: 600), meeting("first", startsIn: 400)], now: now, limit: 2)
        #expect(plan.map(\.meeting.id) == ["first", "second"])
    }

    @Test func customLeadTimeIsRespected() {
        let plan = ReminderPlan.make(meetings: [meeting("event", startsIn: 600)], leadTime: 300, now: now)
        #expect(plan.first?.fireDate == now.addingTimeInterval(300))
    }

    @Test func invalidLeadTimeCannotCreateAnInvalidTrigger() {
        let meeting = meeting("event", startsIn: 600)
        #expect(ReminderPlan.make(meetings: [meeting], leadTime: .nan, now: now).first?.fireDate == now.addingTimeInterval(480))
        #expect(ReminderPlan.make(meetings: [meeting], leadTime: -300, now: now).first?.fireDate == meeting.startDate)
        #expect(ReminderPlan.make(meetings: [meeting], now: now, limit: -1).isEmpty)
    }

    @Test func identifiersAreStableAndDoNotContainCalendarData() {
        let id = ReminderPlan.identifier(for: "user@example.com/calendar/private-meeting")
        #expect(id == ReminderPlan.identifier(for: "user@example.com/calendar/private-meeting"))
        #expect(!id.contains("example.com"))
        #expect(id != ReminderPlan.identifier(for: "different-event"))
    }

    @Test func subsequentRefreshDoesNotRepeatPastReminder() {
        let meeting = meeting("event", startsIn: 600)
        #expect(ReminderPlan.make(meetings: [meeting], now: now).count == 1)
        #expect(ReminderPlan.make(meetings: [meeting], now: now.addingTimeInterval(481)).isEmpty)
    }
}
