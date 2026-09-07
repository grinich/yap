import AVFoundation
import Foundation
import Observation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Recording library", .serialized) @MainActor
struct RecordingLibraryTests {
    @Test func fastAccountMutationClearsRecordingsWithoutWaitingForAViewUpdate() async throws {
        let connection = ZoomConnectionModel(client: ZoomAccountClient(store: RecordingLibraryUnusedStore()))
        let preferences = try #require(UserDefaults(suiteName: "Recordings-account-test-\(UUID().uuidString)"))
        let app = WhooshModel(preview: true, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()), zoomConnection: connection,
            reminders: WhooshReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
        let oldRevision = connection.accountRevision
        let sample = try #require(app.recordings.meetings.first)
        app.recordings.select(sample)
        #expect(app.recordings.selectedMeeting != nil)
        await connection.disconnect()
        #expect(connection.accountRevision != oldRevision)
        #expect(app.recordings.meetings.isEmpty)
        #expect(app.recordings.selectedMeeting == nil)
        #expect(app.recordings.player.currentItem == nil)
        #expect(!app.recordings.hasLoadedInitial)
    }

    @Test func previewSelectionNeverRequestsCloudMediaAndDismissRetainsTheSelection() async throws {
        let fixture = RecordingLibraryPages(pages: [])
        let model = makeModel(fixture)
        model.enterPreview()
        model.isPresented = true
        let sample = try #require(model.meetings.first)
        model.select(sample)
        model.downloadSelected()
        await model.loadInitial()
        await model.refreshForPresentation()
        await model.refresh()
        await model.loadOlder()
        await model.retryLoading()
        #expect(model.selectedFile != nil)
        #expect(model.chat.isPresented)
        #expect(!model.chat.messages.isEmpty)
        #expect(model.player.currentItem == nil)
        #expect(!model.isDownloading)
        #expect(await fixture.calls.isEmpty)
        model.dismiss()
        #expect(!model.isPresented)
        #expect(model.selectedFile == sample.playableVideoFiles.first)
        model.toggle()
        #expect(model.isPresented)
        #expect(model.selectedFile == sample.playableVideoFiles.first)
    }

    @Test func startingARecordingLoadsAndOpensItsChatWithoutAToggle() async throws {
        let client = ZoomAccountClient(store: RecordingLibraryUnusedStore(), transport: ZoomHTTPTransport { _ in
            throw URLError(.unsupportedURL)
        })
        let model = RecordingLibraryModel(client: client,
            makePlaybackSource: { _ in RecordingPlaybackSource(item: AVPlayerItem(asset: AVMutableComposition())) },
            fetchChat: { _ in "00:00:01\tAda: Recorded message" })
        defer { model.clear() }
        let chat = ZoomRecordingFile(id: "chat", recordingType: "chat_file", fileType: "CHAT", fileSize: 100,
            downloadURL: URL(string: "https://zoom.us/rec/download/chat"), playURL: nil, status: "completed")
        let video = ZoomRecordingFile(id: "video", recordingType: "gallery_view", fileType: "MP4", fileSize: 100,
            downloadURL: URL(string: "https://zoom.us/rec/download/video"), playURL: nil, status: "completed")
        model.select(.init(id: "chat-only", topic: "Chat without video", startTime: .now, duration: 1, files: [chat]))
        #expect(model.selectedFile == nil)
        #expect(!model.chat.isLoading)
        #expect(!model.chat.isPresented)

        model.select(.init(id: "with-video", topic: "Video with chat", startTime: .now, duration: 1, files: [video, chat]))
        #expect(model.selectedFile?.id == video.id)
        #expect(model.chat.isLoading)
        #expect(!model.chat.isPresented)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.chat.hasLoaded, model.chat.error == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.chat.hasLoaded)
        #expect(model.chat.messages.map(\.text) == ["Recorded message"])
        #expect(model.chat.isPresented)
    }

    @Test(arguments: [
        ("2024-03-31T23:59:59Z", "2024-03-01T00:00:00Z", "2024-02-01T00:00:00Z", "2024-02-29T00:00:00Z"),
        ("2025-03-01T00:00:00Z", "2025-03-01T00:00:00Z", "2025-02-01T00:00:00Z", "2025-02-28T00:00:00Z"),
        ("2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", "2025-12-01T00:00:00Z", "2025-12-31T00:00:00Z"),
        ("2026-09-01T00:30:00+02:00", "2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z", "2026-07-31T00:00:00Z")
    ])
    func monthWindowsCoverLeapDaysYearBoundariesAndUTC(
        now: String, start: String, previousStart: String, previousEnd: String
    ) throws {
        let date = try date(now)
        let window = RecordingMonthWindow.containing(date)
        #expect(window.from == (try self.date(start)))
        #expect(window.to == date)
        #expect(window.previous.from == (try self.date(previousStart)))
        #expect(window.previous.to == (try self.date(previousEnd)))
        let nextDay = try #require(RecordingMonthWindow.calendar.date(byAdding: .day, value: 1, to: window.previous.to))
        #expect(nextDay == window.from)
    }

    @Test func exhaustsPagesBeforeOlderMonthsAndDeduplicatesNewestFirst() async throws {
        let first = try meeting("duplicate", date: "2026-09-02T12:00:00Z", topic: "Original topic")
        let updated = try meeting("duplicate", date: "2026-09-02T12:00:00Z", topic: "Updated topic")
        let newer = try meeting("newer", date: "2026-09-05T12:00:00Z")
        let older = try meeting("older", date: "2026-08-12T12:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [first], nextPageToken: "opaque+/=&cursor"),
            .init(meetings: [newer, updated]),
            .init(meetings: [older, updated]),
            .init(meetings: [])
        ])
        let model = makeModel(fixture)
        let now = try date("2026-09-06T12:00:00Z")
        await model.loadInitial(now: now)

        let calls = await fixture.calls
        #expect(calls.map(\.token) == ["", "opaque+/=&cursor", "", ""])
        #expect(calls.map(\.from) == (try [
            date("2026-09-01T00:00:00Z"), date("2026-09-01T00:00:00Z"),
            date("2026-08-01T00:00:00Z"), date("2026-07-01T00:00:00Z")
        ]))
        #expect(calls.map(\.to) == (try [now, now, date("2026-08-31T00:00:00Z"), date("2026-07-31T00:00:00Z")]))
        #expect(model.meetings.map(\.id) == ["newer", "duplicate", "older"])
        #expect(model.meetings.first(where: { $0.id == "duplicate" })?.topic == "Updated topic")
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))
        #expect(model.hasLoadedInitial)
        #expect(!model.isLoading)
        #expect(model.error == nil)

        await model.loadInitial(now: now)
        #expect(await fixture.calls.count == 4)
    }

    @Test func emptyMonthsStillAllowFindingOlderRecordings() async throws {
        let older = try meeting("june", date: "2026-06-15T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: []), .init(meetings: []), .init(meetings: []), .init(meetings: [older])
        ])
        let model = makeModel(fixture)
        await model.loadInitial(now: try date("2026-09-06T12:00:00Z"))
        #expect(model.meetings.isEmpty)
        #expect(model.hasLoadedInitial)
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))

        await model.loadOlder()
        #expect(model.meetings == [older])
        #expect(model.oldestLoadedDate == (try date("2026-06-01T00:00:00Z")))
        #expect(await fixture.calls.count == 4)
        #expect(model.error == nil)
    }

    @Test func rejectsRepeatedPageTokensWithoutPublishingAnIncompleteMonth() async throws {
        let partial = try meeting("partial", date: "2026-09-03T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [partial], nextPageToken: "repeated"),
            .init(meetings: [], nextPageToken: "repeated"),
            .init(meetings: [partial]), .init(meetings: []), .init(meetings: [])
        ])
        let model = makeModel(fixture)
        let now = try date("2026-09-06T12:00:00Z")
        await model.loadInitial(now: now)
        #expect(await fixture.calls.count == 2)
        #expect(model.meetings.isEmpty)
        #expect(model.oldestLoadedDate == nil)
        #expect(!model.hasLoadedInitial)
        #expect(!model.isLoading)
        #expect(model.error == ZoomAccountError.invalidResponse.localizedDescription)

        await model.loadInitial(now: now)
        #expect(await fixture.calls.map(\.token) == ["", "repeated", "", "", ""])
        #expect(model.meetings == [partial])
        #expect(model.hasLoadedInitial)
        #expect(model.error == nil)
    }

    @Test(arguments: [false, true])
    func clearRejectsDelayedResultsAndLeavesInitialLoadRetryable(cancel: Bool) async throws {
        let stale = try meeting("old-account", date: "2026-09-03T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [.init(meetings: [stale])], pausedRequests: [1])
        let model = makeModel(fixture)
        let now = try date("2026-09-06T12:00:00Z")
        let load = Task { await model.loadInitial(now: now) }
        await fixture.waitForPause(1)
        #expect(model.isLoading)
        model.clear()
        if cancel { load.cancel() }
        await fixture.resume(1)
        await load.value

        #expect(model.meetings.isEmpty)
        #expect(model.oldestLoadedDate == nil)
        #expect(!model.hasLoadedInitial)
        #expect(!model.isLoading)
        #expect(model.error == nil)
        #expect(await fixture.calls.count == 1)
    }

    @Test func staleCompletionCannotFinishANewerInitialLoad() async throws {
        let stale = try meeting("old-account", date: "2026-09-03T09:00:00Z")
        let current = try meeting("current-account", date: "2026-09-04T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [stale]), .init(meetings: [current]), .init(meetings: []), .init(meetings: [])
        ], pausedRequests: [1, 2])
        let model = makeModel(fixture)
        let now = try date("2026-09-06T12:00:00Z")
        let oldLoad = Task { await model.loadInitial(now: now) }
        await fixture.waitForPause(1)
        model.clear()
        let currentLoad = Task { await model.loadInitial(now: now) }
        await fixture.waitForPause(2)

        await fixture.resume(1)
        await oldLoad.value
        #expect(model.meetings.isEmpty)
        #expect(model.isLoading)
        #expect(!model.hasLoadedInitial)

        await fixture.resume(2)
        await currentLoad.value
        #expect(model.meetings == [current])
        #expect(model.hasLoadedInitial)
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }

    @Test func cancelledInitialLoadDiscardsItsPageAndCanRetryTheSameMonth() async throws {
        let current = try meeting("current", date: "2026-09-04T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [current]), .init(meetings: [current]), .init(meetings: []), .init(meetings: [])
        ], pausedRequests: [1])
        let model = makeModel(fixture)
        let now = try date("2026-09-06T12:00:00Z")
        let load = Task { await model.loadInitial(now: now) }
        await fixture.waitForPause(1)
        load.cancel()
        await fixture.resume(1)
        await load.value
        #expect(model.meetings.isEmpty)
        #expect(!model.hasLoadedInitial)
        #expect(!model.isLoading)
        #expect(model.error == nil)

        await model.loadInitial(now: now)
        let calls = await fixture.calls
        #expect(calls[0].from == calls[1].from)
        #expect(calls[0].to == calls[1].to)
        #expect(model.meetings == [current])
        #expect(model.hasLoadedInitial)
    }

    @Test func refreshUpsertsCompletePagesWithoutReplacingTheSelectedSnapshotOrSearch() async throws {
        let original = try meeting("selected", date: "2026-09-03T09:00:00Z", topic: "Original")
        let updated = try meeting("selected", date: "2026-09-03T09:00:00Z", topic: "Updated")
        let new = try meeting("new", date: "2026-09-06T09:00:00Z")
        let historical = try meeting("historical", date: "2026-07-04T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [original]), .init(meetings: []), .init(meetings: [historical]),
            .init(meetings: [new], nextPageToken: "refresh-page-2"),
            .init(meetings: [updated]), .init(meetings: []), .init(meetings: [])
        ])
        let model = makeModel(fixture)
        defer { model.clear() }
        let now = try date("2026-09-07T12:00:00Z")
        await model.refreshForPresentation(now: now)
        model.select(original)
        model.search = "Original"
        await model.refreshForPresentation(now: now)

        #expect(model.meetings == [new, updated, historical])
        #expect(model.selectedMeeting == original)
        #expect(model.selectedFile == nil)
        #expect(model.search == "Original")
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))
        #expect(model.hasLoadedInitial)
        #expect(!model.isLoading && !model.isRefreshing)
        #expect(model.error == nil)
        #expect(await fixture.calls.map(\.token) == ["", "", "", "", "refresh-page-2", "", ""])
    }

    @Test func unchangedOrAbsentRefreshResultsDoNotRepublishTheMeetingArray() async throws {
        let current = try meeting("current", date: "2026-09-03T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [current]), .init(meetings: []), .init(meetings: []),
            .init(meetings: [current]), .init(meetings: []), .init(meetings: [])
        ])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        let changes = RecordingLibraryChangeCounter()
        withObservationTracking { _ = model.meetings } onChange: { changes.increment() }
        await model.refresh(now: now)
        #expect(model.meetings == [current])
        #expect(changes.value == 0)
    }

    @Test func refreshIncludesOlderLoadedMonthsAndANewMonthWithoutMovingTheOlderCursor() async throws {
        let historical = try meeting("june", date: "2026-06-03T09:00:00Z", topic: "Original")
        let updated = try meeting("june", date: "2026-06-03T09:00:00Z", topic: "Changed in June")
        let newest = try meeting("october", date: "2026-10-02T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: []), .init(meetings: []), .init(meetings: []), .init(meetings: [historical]),
            .init(meetings: [newest]), .init(meetings: []), .init(meetings: []), .init(meetings: []),
            .init(meetings: [updated]), .init(meetings: [])
        ])
        let model = makeModel(fixture)
        await model.loadInitial(now: try date("2026-09-07T12:00:00Z"))
        await model.loadOlder()
        let now = try date("2026-10-04T12:00:00Z")
        await model.refresh(now: now)
        #expect(model.meetings == [newest, updated])
        #expect(model.oldestLoadedDate == (try date("2026-06-01T00:00:00Z")))
        await model.loadOlder()

        let calls = await fixture.calls
        #expect(calls.dropFirst(4).map(\.from) == (try [
            date("2026-10-01T00:00:00Z"), date("2026-09-01T00:00:00Z"),
            date("2026-08-01T00:00:00Z"), date("2026-07-01T00:00:00Z"),
            date("2026-06-01T00:00:00Z"), date("2026-05-01T00:00:00Z")
        ]))
        #expect(calls[4].to == now)
        #expect(calls[5].to == (try date("2026-09-30T00:00:00Z")))
        #expect(model.oldestLoadedDate == (try date("2026-05-01T00:00:00Z")))
    }

    @Test func failedRefreshRetainsHistoryAndRetriesTheIncompleteMonthBeforeContinuing() async throws {
        let historical = try meeting("history", date: "2026-07-03T09:00:00Z")
        let newest = try meeting("new", date: "2026-09-06T09:00:00Z")
        let partial = try meeting("partial", date: "2026-08-03T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: []), .init(meetings: []), .init(meetings: [historical]),
            .init(meetings: [newest]), .init(meetings: [partial], nextPageToken: "failing-page"),
            .init(meetings: []), .init(meetings: [partial]), .init(meetings: []), .init(meetings: [])
        ], failedRequests: [6])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        await model.refresh(now: now)
        #expect(model.meetings == [newest, historical])
        #expect(model.error != nil)
        #expect(model.hasLoadedInitial)
        #expect(!model.isRefreshing)
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))

        await model.retryLoading()
        #expect(model.meetings == [newest, partial, historical])
        #expect(model.error == nil)
        await model.loadOlder()
        let calls = await fixture.calls
        #expect(calls.count == 9)
        #expect(calls[6].from == calls[4].from)
        #expect(calls[6].token.isEmpty)
        #expect(calls[7].from == (try date("2026-07-01T00:00:00Z")))
        #expect(calls[8].from == (try date("2026-06-01T00:00:00Z")))
    }

    @Test func initialAndOlderRetriesResumeTheFailedWindowWithoutSkippingOrAddingMonths() async throws {
        let fixture = RecordingLibraryPages(pages: Array(repeating: .init(meetings: []), count: 7),
                                            failedRequests: [2, 5])
        let model = makeModel(fixture)
        await model.loadInitial(now: try date("2026-09-07T12:00:00Z"))
        #expect(!model.hasLoadedInitial)
        #expect(model.oldestLoadedDate == (try date("2026-09-01T00:00:00Z")))
        await model.retryLoading()
        #expect(model.hasLoadedInitial)
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))
        await model.loadOlder()
        #expect(model.error != nil)
        await model.retryLoading()
        #expect(model.error == nil)
        #expect(model.oldestLoadedDate == (try date("2026-06-01T00:00:00Z")))
        await model.loadOlder()
        #expect(await fixture.calls.map(\.from) == (try [
            date("2026-09-01T00:00:00Z"), date("2026-08-01T00:00:00Z"),
            date("2026-08-01T00:00:00Z"), date("2026-07-01T00:00:00Z"),
            date("2026-06-01T00:00:00Z"), date("2026-06-01T00:00:00Z"), date("2026-05-01T00:00:00Z")
        ]))
    }

    @Test(arguments: [false, true])
    func concurrentPresentationsShareSuccessfulLoadsAndRetryCancelledRefreshes(cancel: Bool) async throws {
        let historical = try meeting("history", date: "2026-07-03T09:00:00Z")
        let partial = try meeting("partial", date: "2026-09-05T09:00:00Z")
        let newest = try meeting("new", date: "2026-09-06T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: []), .init(meetings: []), .init(meetings: [historical]),
            .init(meetings: [partial], nextPageToken: "last-page"), .init(meetings: []),
            .init(meetings: [newest]), .init(meetings: []), .init(meetings: [])
        ], pausedRequests: [5])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.refreshForPresentation(now: now)
        let first = Task { await model.refreshForPresentation(now: now) }
        await fixture.waitForPause(5)
        #expect(model.isRefreshing)
        #expect(model.meetings == [historical])
        if cancel { first.cancel() }
        let arrived = AsyncStream<Void>.makeStream()
        let second = Task {
            arrived.continuation.yield()
            await model.refreshForPresentation(now: now)
        }
        for await _ in arrived.stream { break }
        #expect(await fixture.calls.count == 5)
        await fixture.resume(5)
        await first.value
        await second.value

        #expect(await fixture.calls.count == (cancel ? 8 : 7))
        #expect(model.meetings == (cancel ? [newest, historical] : [newest, partial, historical]))
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))
        #expect(model.hasLoadedInitial)
        #expect(!model.isLoading && !model.isRefreshing)
        #expect(model.error == nil)
    }

    @Test(arguments: [(false, false), (true, false), (false, true)])
    func explicitOlderRequestsWaitForRefreshAndShareOneMonth(cancelFirst: Bool, olderFails: Bool) async throws {
        let historical = try meeting("history", date: "2026-07-03T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: []), .init(meetings: []), .init(meetings: [historical]),
            .init(meetings: []), .init(meetings: []), .init(meetings: []), .init(meetings: [])
        ], pausedRequests: [4], failedRequests: olderFails ? [7] : [])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        let refresh = Task { await model.refresh(now: now) }
        await fixture.waitForPause(4)
        let arrived = AsyncStream<Void>.makeStream()
        let first = Task {
            arrived.continuation.yield()
            await model.loadOlder()
        }
        let second = Task {
            arrived.continuation.yield()
            await model.loadOlder()
        }
        var arrivals = 0
        for await _ in arrived.stream {
            arrivals += 1
            if arrivals == 2 { break }
        }
        #expect(model.isRefreshing && model.isLoadingOlder)
        #expect(await fixture.calls.count == 4)
        if cancelFirst { first.cancel() }
        await fixture.resume(4)
        await refresh.value
        await first.value
        await second.value

        let calls = await fixture.calls
        #expect(calls.count == 7)
        #expect(calls.last?.from == (try date("2026-06-01T00:00:00Z")))
        #expect(model.oldestLoadedDate == (try date(olderFails ? "2026-07-01T00:00:00Z" : "2026-06-01T00:00:00Z")))
        #expect(model.meetings == [historical])
        #expect(!model.isLoadingOlder && !model.isLoading && !model.isRefreshing)
        #expect((model.error != nil) == olderFails)
    }

    @Test func anExplicitOlderRequestStillRunsAfterRefreshFails() async throws {
        let fixture = RecordingLibraryPages(pages: Array(repeating: .init(meetings: []), count: 5),
                                            pausedRequests: [4], failedRequests: [4])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        let refresh = Task { await model.refresh(now: now) }
        await fixture.waitForPause(4)
        let arrived = AsyncStream<Void>.makeStream()
        let older = Task {
            arrived.continuation.yield()
            await model.loadOlder()
        }
        for await _ in arrived.stream { break }
        #expect(model.isLoadingOlder)
        await fixture.resume(4)
        await refresh.value
        await older.value

        #expect(await fixture.calls.count == 5)
        #expect(await fixture.calls.last?.from == (try date("2026-06-01T00:00:00Z")))
        #expect(model.oldestLoadedDate == (try date("2026-06-01T00:00:00Z")))
        #expect(!model.isLoadingOlder && !model.isLoading && !model.isRefreshing)
        #expect(model.error == nil)
    }

    @Test func cancellingAQueuedOlderRequestLeavesTheMonthAvailableForTheNextClick() async throws {
        let fixture = RecordingLibraryPages(pages: Array(repeating: .init(meetings: []), count: 7),
                                            pausedRequests: [4])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        let refresh = Task { await model.refresh(now: now) }
        await fixture.waitForPause(4)
        let arrived = AsyncStream<Void>.makeStream()
        let older = Task {
            arrived.continuation.yield()
            await model.loadOlder()
        }
        for await _ in arrived.stream { break }
        #expect(model.isLoadingOlder)
        older.cancel()
        await fixture.resume(4)
        await refresh.value
        await older.value
        #expect(await fixture.calls.count == 6)
        #expect(!model.isLoadingOlder)
        #expect(model.oldestLoadedDate == (try date("2026-07-01T00:00:00Z")))

        await model.loadOlder()
        #expect(await fixture.calls.count == 7)
        #expect(model.oldestLoadedDate == (try date("2026-06-01T00:00:00Z")))
        #expect(model.error == nil)
    }

    @Test func staleRefreshCannotMergeIntoOrFinishANewAccountsLoad() async throws {
        let stale = try meeting("old-account", date: "2026-09-03T09:00:00Z")
        let current = try meeting("current-account", date: "2026-09-04T09:00:00Z")
        let fixture = RecordingLibraryPages(pages: [
            .init(meetings: [stale]), .init(meetings: []), .init(meetings: []), .init(meetings: [stale]),
            .init(meetings: [current]), .init(meetings: []), .init(meetings: [])
        ], pausedRequests: [4, 5])
        let model = makeModel(fixture)
        let now = try date("2026-09-07T12:00:00Z")
        await model.loadInitial(now: now)
        let oldRefresh = Task { await model.refresh(now: now) }
        await fixture.waitForPause(4)
        let arrived = AsyncStream<Void>.makeStream()
        let oldOlder = Task {
            arrived.continuation.yield()
            await model.loadOlder()
        }
        for await _ in arrived.stream { break }
        #expect(model.isLoadingOlder)
        model.clear()
        #expect(!model.isLoadingOlder)
        await oldOlder.value
        let currentLoad = Task { await model.refreshForPresentation(now: now) }
        await fixture.waitForPause(5)
        await fixture.resume(4)
        await oldRefresh.value
        #expect(model.meetings.isEmpty)
        #expect(model.isLoading)
        #expect(!model.isRefreshing)
        #expect(!model.hasLoadedInitial)
        await fixture.resume(5)
        await currentLoad.value
        #expect(model.meetings == [current])
        #expect(model.hasLoadedInitial)
        #expect(!model.isLoading && !model.isRefreshing)
        #expect(!model.isLoadingOlder)
        #expect(model.error == nil)
    }

    private func makeModel(_ fixture: RecordingLibraryPages) -> RecordingLibraryModel {
        // Neither Keychain nor live HTTP is reachable from these fixtures.
        let client = ZoomAccountClient(store: RecordingLibraryUnusedStore(), transport: ZoomHTTPTransport { _ in
            throw URLError(.unsupportedURL)
        })
        return RecordingLibraryModel(client: client, fetchPage: { from, to, token in
            try await fixture.fetch(from: from, to: to, token: token)
        })
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func meeting(_ id: String, date value: String, topic: String = "Fixture recording") throws -> ZoomRecordingMeeting {
        .init(id: id, topic: topic, startTime: try date(value), duration: 30, files: [])
    }
}

private actor RecordingLibraryPages {
    struct Call: Sendable {
        let from: Date
        let to: Date
        let token: String
    }

    private let pages: [ZoomRecordingPage]
    private let pausedRequests: Set<Int>
    private let failedRequests: Set<Int>
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [Call] = []

    init(pages: [ZoomRecordingPage], pausedRequests: Set<Int> = [], failedRequests: Set<Int> = []) {
        self.pages = pages
        self.pausedRequests = pausedRequests
        self.failedRequests = failedRequests
    }

    func fetch(from: Date, to: Date, token: String) async throws -> ZoomRecordingPage {
        calls.append(.init(from: from, to: to, token: token))
        let request = calls.count
        guard pages.indices.contains(request - 1) else { throw ZoomAccountError.invalidResponse }
        if pausedRequests.contains(request) {
            await withCheckedContinuation { continuation in
                gates[request] = continuation
                waiters.removeValue(forKey: request)?.resume()
            }
        }
        if failedRequests.contains(request) { throw ZoomAccountError.invalidResponse }
        return pages[request - 1]
    }

    func waitForPause(_ request: Int) async {
        if gates[request] != nil { return }
        await withCheckedContinuation { waiters[request] = $0 }
    }

    func resume(_ request: Int) { gates.removeValue(forKey: request)?.resume() }
}

private final class RecordingLibraryChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor RecordingLibraryUnusedStore: ZoomCredentialStore {
    func loadConfiguration() -> ZoomPersonalConfiguration? { nil }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) {}
    func loadTokens() -> ZoomOAuthTokens? { nil }
    func saveTokens(_ value: ZoomOAuthTokens) {}
    func deleteTokens() {}
    func deleteAll() {}
}
