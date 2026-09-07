import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Recording date and title search") @MainActor
struct RecordingSearchTests {
    @Test func blankAndFoldedTitleQueriesKeepExistingTitleSearchUseful() throws {
        let recording = try meeting("2026-09-07T19:00:00Z", title: "Café Résumé — Product DESIGN Review")
        for query in ["", "  \n\t ", "CAFE", "resume", "Product DESIGN", "prod des"] {
            #expect(try search(query).matches(recording), "Query: \(query)")
        }
        #expect(try !search("finance").matches(recording))
        #expect(try !search("prod finance").matches(recording))
        #expect(try !search("team match").matches(meeting("2026-03-03T20:00:00Z", title: "Team review")))
        #expect(try search("team match").matches(meeting("2026-09-07T19:00:00Z", title: "Team match review")))
        #expect(try search("team match 3").matches(meeting("2026-03-03T20:00:00Z", title: "Team review")))
        #expect(try !search("team match 3").matches(meeting("2026-03-04T20:00:00Z", title: "Team review")))
        #expect(try !search("match review 2026").matches(meeting("2026-03-03T20:00:00Z", title: "Review")))
        #expect(try search("match review 2026").matches(meeting("2026-09-03T19:00:00Z", title: "Match review")))
    }

    @Test(arguments: ["Sep", "Sept", "September", "sEpTeMbEr", "Sepember"])
    func recognizesSeptemberNamesAbbreviationsAndOneMissingLetter(_ query: String) throws {
        #expect(try search(query).matches(meeting("2026-09-07T19:00:00Z")))
        #expect(try search(query).matches(meeting("2025-09-21T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-08-07T19:00:00Z")))
    }

    @Test func toleratesAMissingLetterInAugustWithoutMatchingAnotherMonth() throws {
        #expect(try search("Augst").matches(meeting("2026-08-21T19:00:00Z")))
        #expect(try !search("Augst").matches(meeting("2026-09-21T19:00:00Z")))
    }

    @Test(arguments: ["Sep 7", "7 Sep", "September 7th", "7th September", "9/7"])
    func monthAndDayQueriesMatchAcrossYearsAndRequireBothComponents(_ query: String) throws {
        #expect(try search(query).matches(meeting("2026-09-07T19:00:00Z")))
        #expect(try search(query).matches(meeting("2024-09-07T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-09-08T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-07-09T19:00:00Z")))
    }

    @Test(arguments: ["9/7/2026", "9/7/26", "2026-09-07", "September 7 2026"])
    func fullDatesRequireTheYearMonthAndDay(_ query: String) throws {
        #expect(try search(query).matches(meeting("2026-09-07T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2025-09-07T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-09-08T19:00:00Z")))
    }

    @Test func numericDatesRespectLocaleOrderingAndUnambiguousDayFirstInput() throws {
        let september = try meeting("2026-09-07T19:00:00Z")
        let july = try meeting("2026-07-09T19:00:00Z")
        let british = try search("7/9/2026", locale: Locale(identifier: "en_GB"))
        #expect(british.matches(september))
        #expect(!british.matches(july))
        let american = try search("7/9/2026")
        #expect(american.matches(july))
        #expect(!american.matches(september))
        #expect(try search("21/9").matches(meeting("2026-09-21T19:00:00Z")))
        #expect(try search("2026-09-07", locale: Locale(identifier: "en_GB")).matches(september))
        #expect(try search("9/3/26").matches(meeting("2026-09-03T19:00:00Z")))
        #expect(try !search("9/3/26").matches(meeting("2025-09-03T19:00:00Z")))
    }

    @Test func yearAndCalendarDateUseTheVisibleLocalDateInsteadOfUTC() throws {
        let lateSunday = try meeting("2026-09-07T06:30:00Z")
        #expect(try search("Sep 6").matches(lateSunday))
        #expect(try !search("Sep 7").matches(lateSunday))
        #expect(try search("2026").matches(meeting("2027-01-01T07:59:59Z")))
        #expect(try !search("2026").matches(meeting("2027-01-01T08:00:00Z")))
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcSearch = RecordingSearch(query: "Sep 7", now: try instant(defaultNow), calendar: utc, locale: locale)
        #expect(utcSearch.matches(lateSunday))
    }

    @Test func weekdayIsRecurringWhileLastWeekdayIsStrictlyBeforeToday() throws {
        let today = try meeting("2026-09-07T19:00:00Z")
        let previousMonday = try meeting("2026-08-31T19:00:00Z")
        let earlierMonday = try meeting("2026-08-24T19:00:00Z")
        #expect(try search("Monday").matches(today))
        #expect(try search("Monday").matches(previousMonday))
        #expect(try !search("Monday").matches(meeting("2026-09-06T19:00:00Z")))
        #expect(try search("last Monday").matches(previousMonday))
        #expect(try !search("last Monday").matches(today))
        #expect(try !search("last Monday").matches(earlierMonday))
    }

    @Test(arguments: [
        ("today", "2026-09-07T07:00:00Z", "2026-09-08T06:59:59Z", "2026-09-07T06:59:59Z", "2026-09-08T07:00:00Z"),
        ("yesterday", "2026-09-06T07:00:00Z", "2026-09-07T06:59:59Z", "2026-09-06T06:59:59Z", "2026-09-07T07:00:00Z"),
        ("this week", "2026-09-07T07:00:00Z", "2026-09-14T06:59:59Z", "2026-09-07T06:59:59Z", "2026-09-14T07:00:00Z"),
        ("last week", "2026-08-31T07:00:00Z", "2026-09-07T06:59:59Z", "2026-08-31T06:59:59Z", "2026-09-07T07:00:00Z"),
        ("this month", "2026-09-01T07:00:00Z", "2026-10-01T06:59:59Z", "2026-09-01T06:59:59Z", "2026-10-01T07:00:00Z"),
        ("last month", "2026-08-01T07:00:00Z", "2026-09-01T06:59:59Z", "2026-08-01T06:59:59Z", "2026-09-01T07:00:00Z")
    ])
    func relativePeriodsIncludeTheirLocalStartAndExcludeTheirEnd(
        query: String, start: String, lastSecond: String, before: String, end: String
    ) throws {
        let matcher = try search(query)
        #expect(try matcher.matches(meeting(start)))
        #expect(try matcher.matches(meeting(lastSecond)))
        #expect(try !matcher.matches(meeting(before)))
        #expect(try !matcher.matches(meeting(end)))
    }

    @Test func relativePeriodsUseCalendarArithmeticAcrossDSTAndNewYear() throws {
        let yesterday = try search("yesterday", now: "2026-03-09T19:00:00Z")
        #expect(try yesterday.matches(meeting("2026-03-08T08:00:00Z")))
        #expect(try yesterday.matches(meeting("2026-03-09T06:59:59Z")))
        #expect(try !yesterday.matches(meeting("2026-03-08T07:59:59Z")))
        #expect(try !yesterday.matches(meeting("2026-03-09T07:00:00Z")))
        let lastMonth = try search("last month", now: "2027-01-07T20:00:00Z")
        #expect(try lastMonth.matches(meeting("2026-12-15T20:00:00Z")))
        #expect(try !lastMonth.matches(meeting("2027-01-01T20:00:00Z")))
        #expect(try !lastMonth.matches(meeting("2025-12-15T20:00:00Z")))
    }

    @Test func mixedTitleAndDateTermsNarrowResultsWithoutBreakingLiteralDateWordsInTitles() throws {
        let target = try meeting("2026-09-07T19:00:00Z", title: "Product design review")
        for query in ["prod des Sep 7", "September 7 prod des", "prod yesterday"] {
            let matcher = try search(query, now: query.contains("yesterday") ? "2026-09-08T19:00:00Z" : defaultNow)
            #expect(matcher.matches(target), "Query: \(query)")
        }
        #expect(try !search("prod Sep 8").matches(target))
        #expect(try !search("finance Sep 7").matches(target))
        #expect(try !search("prod Sep 7").matches(meeting("2026-09-07T19:00:00Z", title: "Finance review")))
        #expect(try search("May forecast").matches(meeting("2026-09-07T19:00:00Z", title: "May forecast planning")))
        #expect(try search("SOC2 Sep3").matches(meeting("2026-09-03T19:00:00Z", title: "SOC2 audit")))
        #expect(try !search("SOC2 Sep3").matches(meeting("2026-09-02T19:00:00Z", title: "SOC2 audit")))
        #expect(try !search("SOC2 Sep3").matches(meeting("2026-09-03T19:00:00Z", title: "SOC3 audit")))
        #expect(try search("RFC2026 Aug31").matches(meeting("2025-08-31T19:00:00Z", title: "RFC2026 review")))
        #expect(try !search("RFC2026 Aug31").matches(meeting("2026-08-31T19:00:00Z", title: "RFC2025 review")))
    }

    @Test(arguments: ["Aug31", "31Aug", "Aug31st"])
    func compactMonthDayQueriesMatchWithoutRequiringSpaces(_ query: String) throws {
        #expect(try search(query).matches(meeting("2026-08-31T19:00:00Z")))
        #expect(try search(query).matches(meeting("2024-08-31T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-08-30T19:00:00Z")))
        #expect(try !search(query).matches(meeting("2026-07-31T19:00:00Z")))
    }

    @Test(arguments: ["!!!", "---", "/"])
    func punctuationAloneRequiresALiteralTitleMatch(_ query: String) throws {
        #expect(try !search(query).matches(meeting("2026-09-07T19:00:00Z")))
        #expect(try search(query).matches(meeting("2026-09-07T19:00:00Z", title: "Release \(query) notes")))
    }

    @Test func impossibleExplicitDatesDoNotNormalizeIntoAnotherDay() throws {
        #expect(try search("2024-02-29").matches(meeting("2024-02-29T20:00:00Z")))
        for query in ["2025-02-29", "2026-02-30", "2/30/2026", "13/32/2026"] {
            #expect(try !search(query).matches(meeting("2026-03-02T20:00:00Z")), "Query: \(query)")
            #expect(try !search(query).matches(meeting("2025-03-01T20:00:00Z")), "Query: \(query)")
        }
    }

    private let defaultNow = "2026-09-07T19:00:00Z"
    private var locale: Locale { Locale(identifier: "en_US_POSIX") }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    private func search(_ query: String, now: String? = nil, locale: Locale? = nil) throws -> RecordingSearch {
        RecordingSearch(query: query, now: try instant(now ?? defaultNow), calendar: calendar, locale: locale ?? self.locale)
    }
    private func meeting(_ date: String, title: String = "Fixture recording") throws -> ZoomRecordingMeeting {
        .init(id: date + title, topic: title, startTime: try instant(date), duration: 30, files: [])
    }
    private func instant(_ date: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: date))
    }
}
