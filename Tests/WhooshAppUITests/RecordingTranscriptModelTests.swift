import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Recorded transcript synchronization and search") @MainActor
struct RecordingTranscriptModelTests {
    private let start = Date(timeIntervalSince1970: 1_787_054_400)

    @Test func loadsOnPresentationOrPlaybackAndKeepsStateAcrossTabs() async throws {
        let fixture = TranscriptModelFixture(responses: ["transcript": [vtt("Ada: Café design", start: 5, end: 10)]])
        let model = makeModel(fixture)
        defer { model.clear() }
        let selected = meeting(files: [transcript("transcript")])
        model.select(selected, isPreview: false)
        #expect(model.hasTranscriptFile)
        #expect(!model.hasLoaded)
        #expect(await fixture.calls.isEmpty)

        model.setPlaybackActive(true)
        try await loaded(model)
        #expect(!model.isPresented)
        model.setPresented(true)
        model.query = "cafe"
        model.followsPlayback = false
        let cues = model.cues
        let match = model.currentMatchID
        model.setPresented(false)
        model.select(selected, isPreview: false)
        model.setPresented(true)
        #expect(model.cues == cues)
        #expect(model.query == "cafe")
        #expect(model.currentMatchID == match)
        #expect(!model.followsPlayback)
        #expect(await fixture.calls == ["transcript"])
    }

    @Test func splitTranscriptClocksMapToVideoAndHighlightOnlyDuringCueIntervals() async throws {
        let first = transcript("first", start: start.addingTimeInterval(300))
        let second = transcript("second", start: start.addingTimeInterval(330))
        let fixture = TranscriptModelFixture(responses: [
            "first": ["WEBVTT\n\n00:00:05.000 --> 00:00:10.000\nAda: First\n\n00:00:07.000 --> 00:00:12.000\nLin: Overlap\n"],
            "second": [vtt("Sam: Second segment", start: 5, end: 9)]
        ])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(files: [second, first]), isPreview: false)
        model.setPresented(true)
        try await loaded(model)
        #expect(model.cues.map(\.start) == [5, 7, 35])
        let firstCue = try #require(model.cues.first)
        let secondCue = try #require(model.cues.last)
        let video = video(start: start.addingTimeInterval(300), end: start.addingTimeInterval(360))

        model.synchronize(playerTime: 8, file: video, duration: 60)
        #expect(model.activeCueIDs == Set(model.cues.prefix(2).map(\.id)))
        #expect(model.playbackTime(for: secondCue) == 35)
        model.synchronize(playerTime: 10, file: video, duration: 60)
        #expect(model.activeCueIDs == [model.cues[1].id])
        model.synchronize(playerTime: 12, file: video, duration: 60)
        #expect(model.activeCueIDs.isEmpty)
        #expect(model.scrollTargetID == model.cues[1].id)
        model.synchronize(playerTime: 36, file: video, duration: 60)
        #expect(model.activeCueIDs == [secondCue.id])
        model.synchronize(playerTime: 4, file: video, duration: 60)
        #expect(model.activeCueIDs.isEmpty)
        #expect(model.scrollTargetID == nil)

        let laterVideo = self.video(start: start.addingTimeInterval(330), end: start.addingTimeInterval(360))
        model.synchronize(playerTime: 5, file: laterVideo, duration: 30)
        #expect(model.playbackTime(for: firstCue) == nil)
        #expect(model.playbackTime(for: secondCue) == 5)
        #expect(model.activeCueIDs == [secondCue.id])
        #expect(await fixture.calls == ["first", "second"])
    }

    @Test(arguments: [false, true])
    func missingTranscriptOrVideoTimestampUsesOriginalVTTClock(missingTranscriptStart: Bool) async throws {
        let fixture = TranscriptModelFixture(responses: ["transcript": [vtt("Ada: Hello", start: 5, end: 10)]])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(files: [transcript("transcript", start: missingTranscriptStart ? nil : start.addingTimeInterval(300))]),
                     isPreview: false)
        model.setPresented(true)
        try await loaded(model)
        model.synchronize(playerTime: 5, file: video(start: missingTranscriptStart ? start.addingTimeInterval(500) : nil), duration: 60)
        let cue = try #require(model.cues.first)
        #expect(model.playbackTime(for: cue) == 5)
        #expect(model.activeCueIDs == [cue.id])
    }

    @Test func clipBoundsInvalidClockAndEditedVideoNoticeAreHandled() async throws {
        let fixture = TranscriptModelFixture(responses: ["transcript": [
            "WEBVTT\n\n00:00:05.000 --> 00:00:10.000\nAda: Beginning\n\n00:00:30.000 --> 00:00:35.000\nLin: Later\n"
        ]])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(files: [transcript("transcript", start: start)]), isPreview: false)
        model.setPresented(true)
        try await loaded(model)
        let first = try #require(model.cues.first)
        let last = try #require(model.cues.last)
        let clipped = video(start: start.addingTimeInterval(7), end: start.addingTimeInterval(100))
        model.synchronize(playerTime: 0, file: clipped, duration: 23)
        #expect(model.playbackTime(for: first) == 0)
        #expect(model.playbackTime(for: last) == nil)
        #expect(model.activeCueIDs == [first.id])
        #expect(model.timingNotice != nil)
        model.synchronize(playerTime: 23, file: clipped, duration: 23)
        #expect(model.activeCueIDs.isEmpty)
        model.synchronize(playerTime: 5, file: video(start: start, end: start.addingTimeInterval(40)), duration: 40)
        #expect(model.timingNotice == nil)
        model.synchronize(playerTime: .infinity, file: clipped, duration: 23)
        #expect(model.activeCueIDs.isEmpty)
        #expect(model.scrollTargetID == nil)
        #expect(model.playbackTime(for: first) == nil)
        #expect(model.timingNotice == nil)
    }

    @Test func searchMatchesCaseDiacriticsSpeakerAndPhrasesWithoutFilteringTheTimeline() async throws {
        let fixture = TranscriptModelFixture(responses: ["transcript": [
            "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nZoë: Café design\n\n00:00:05.000 --> 00:00:08.000\nSam: CAFÉ\ndesign proposal\n\n00:00:09.000 --> 00:00:12.000\nZoë: Something else\n"
        ]])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(files: [transcript("transcript")]), isPreview: false)
        model.setPresented(true)
        try await loaded(model)
        let last = try #require(model.cues.last)
        model.synchronize(playerTime: 10, file: video(), duration: 30)
        model.query = "  CAFE   design "
        #expect(model.matchCount == 2)
        #expect(model.currentMatchIndex == 1)
        #expect(model.matchingCueIDs == model.cues.prefix(2).map(\.id))
        #expect(model.activeCueIDs == [last.id])
        #expect(model.cues.count == 3)
        #expect(model.selectNextMatch()?.id == model.cues[1].id)
        #expect(model.currentMatchIndex == 2)
        #expect(!model.followsPlayback)
        #expect(model.selectNextMatch()?.id == model.cues[0].id)
        #expect(model.currentMatchIndex == 1)
        #expect(model.selectPreviousMatch()?.id == model.cues[1].id)
        model.query = "ZOE"
        #expect(model.matchingCueIDs == [model.cues[0].id, last.id])
        #expect(model.currentMatchIndex == 1)
        model.query = "no matching text"
        #expect(model.matchCount == 0)
        #expect(model.currentMatchIndex == 0)
        #expect(model.currentMatchID == nil)
        #expect(model.selectNextMatch() == nil)
        #expect(model.selectPreviousMatch() == nil)
        model.query = " \n\t "
        #expect(model.matchCount == 0)
        #expect(model.currentMatchIndex == 0)
    }

    @Test func deduplicationAndExportsUseTheCompleteMergedTimeline() async throws {
        let first = transcript("first", start: start)
        let copy = transcript("copy", start: start)
        let later = transcript("later", start: start.addingTimeInterval(60))
        let fixture = TranscriptModelFixture(responses: [
            "first": [vtt("Ada: Fish &amp; chips &lt;today&gt;", start: 5, end: 10)],
            "copy": [vtt("Ada: Fish &amp; chips &lt;today&gt;", start: 5, end: 10)],
            "later": [vtt("Lin: Next segment", start: 2, end: 4)]
        ])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(files: [later, first, copy]), isPreview: false)
        model.setPresented(true)
        try await loaded(model)
        model.query = "Fish"
        #expect(model.cues.count == 2)
        #expect(Set(model.cues.map(\.id)).count == 2)
        #expect(model.transcriptText.contains("[00:00:05] Ada: Fish & chips <today>"))
        #expect(model.transcriptText.contains("[00:01:02] Lin: Next segment"))
        #expect(model.transcriptVTT.hasPrefix("WEBVTT\n\n"))
        #expect(model.transcriptVTT.contains("00:01:02.000 --> 00:01:04.000"))
        #expect(model.transcriptVTT.contains("Fish &amp; chips &lt;today&gt;"))
        let exported = try ZoomRecordingTranscriptParser.parse(model.transcriptVTT)
        #expect(exported.map(\.start) == model.cues.map(\.start))
        #expect(exported.map(\.end) == model.cues.map(\.end))
        #expect(exported.map(\.speaker) == model.cues.map(\.speaker))
        #expect(exported.map(\.text) == model.cues.map(\.text))
    }

    @Test(arguments: [false, true])
    func selectionAndClearRejectStaleAsyncResults(replaceSelection: Bool) async throws {
        let fixture = TranscriptModelFixture(responses: [
            "old": [vtt("Old: Private content", start: 1, end: 3)],
            "new": [vtt("New: Current content", start: 2, end: 5)]
        ], pausedRequests: [1, 2])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(id: "old", files: [transcript("old")]), isPreview: false)
        model.setPresented(true)
        try await waitUntil { await fixture.isPaused(1) }
        model.query = "private"
        if replaceSelection {
            model.select(meeting(id: "new", files: [transcript("new")]), isPreview: false)
            model.setPresented(true)
            try await waitUntil { await fixture.isPaused(2) }
        } else { model.clear() }
        await fixture.resume(1)
        try await waitUntil { await fixture.cancelledReturns.contains(1) }
        await Task.yield()
        await Task.yield()
        #expect(model.cues.isEmpty)
        #expect(model.query.isEmpty)
        #expect(model.matchCount == 0)
        #expect(model.error == nil)
        #expect(model.isLoading == replaceSelection)
        #expect(!model.hasLoaded)
        if replaceSelection {
            await fixture.resume(2)
            try await loaded(model)
            #expect(model.cues.map(\.text) == ["Current content"])
        }
    }

    @Test func retryRecoversFromMalformedContentAndCacheAdoptionCancelsPendingRequest() async throws {
        let fixture = TranscriptModelFixture(responses: ["transcript": ["not a VTT transcript", vtt("Ada: Café design", start: 5, end: 10)]])
        let source = makeModel(fixture)
        let selected = meeting(files: [transcript("transcript")])
        defer { source.clear() }
        source.select(selected, isPreview: false)
        source.setPresented(true)
        try await waitUntil { source.error != nil }
        #expect(!source.hasLoaded)
        source.retry()
        try await loaded(source)
        source.query = "cafe"
        source.followsPlayback = false
        source.synchronize(playerTime: 6, file: video(), duration: 30)

        let childFixture = TranscriptModelFixture(responses: ["transcript": [vtt("Stale: Should not replace cache", start: 1, end: 2)]], pausedRequests: [1])
        let child = makeModel(childFixture)
        defer { child.clear() }
        child.select(selected, isPreview: false)
        child.setPlaybackActive(true)
        try await waitUntil { await childFixture.isPaused(1) }
        child.synchronize(playerTime: 15, file: video(), duration: 30)
        child.adoptState(from: source)
        #expect(child.hasLoaded)
        #expect(!child.isLoading)
        #expect(child.cues == source.cues)
        #expect(child.isPresented)
        #expect(child.query == "cafe")
        #expect(child.currentMatchID == source.currentMatchID)
        #expect(!child.followsPlayback)
        #expect(child.activeCueIDs.isEmpty)
        #expect(!source.activeCueIDs.isEmpty)
        await childFixture.resume(1)
        try await waitUntil { await childFixture.cancelledReturns.contains(1) }
        await Task.yield()
        await Task.yield()
        #expect(child.cues == source.cues)
        source.clear()
        #expect(child.cues.map(\.text) == ["Café design"])
        #expect(child.query == "cafe")
    }

    @Test(arguments: [false, true])
    func emptyAndPreviewRecordingsAvoidNetworkRequests(isPreview: Bool) async throws {
        let fixture = TranscriptModelFixture(responses: [:])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting(), isPreview: isPreview)
        model.setPresented(true)
        try await loaded(model)
        #expect(model.cues.isEmpty == !isPreview)
        #expect(model.hasTranscriptFile == isPreview)
        #expect(await fixture.calls.isEmpty)
    }

    private func makeModel(_ fixture: TranscriptModelFixture) -> RecordingTranscriptModel {
        RecordingTranscriptModel(fetch: { try await fixture.fetch($0) })
    }

    private func meeting(id: String = "meeting", files: [ZoomRecordingFile] = []) -> ZoomRecordingMeeting {
        .init(id: id, topic: "Fixture meeting", startTime: start, duration: 60, files: files)
    }

    private func transcript(_ id: String, start: Date? = nil) -> ZoomRecordingFile {
        .init(id: id, recordingType: "audio_transcript", fileType: "TRANSCRIPT", fileSize: 100,
              downloadURL: URL(string: "https://zoom.us/rec/download/\(id)"), playURL: nil, status: "completed",
              recordingStart: start)
    }

    private func video(start: Date? = nil, end: Date? = nil) -> ZoomRecordingFile {
        .init(id: "video", recordingType: "gallery_view", fileType: "MP4", fileSize: 100,
              downloadURL: URL(string: "https://zoom.us/rec/download/video"), playURL: nil, status: "completed",
              recordingStart: start, recordingEnd: end)
    }

    private func vtt(_ text: String, start: Int, end: Int) -> String {
        String(format: "WEBVTT\n\n00:00:%02d.000 --> 00:00:%02d.000\n%@\n", start, end, text)
    }

    private func loaded(_ model: RecordingTranscriptModel) async throws {
        try await waitUntil { model.hasLoaded || model.error != nil }
        try #require(model.error == nil)
        try #require(model.hasLoaded)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TranscriptModelFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum TranscriptModelFixtureError: Error { case unexpectedFetch, timedOut }

private actor TranscriptModelFixture {
    private var responses: [String: [String]]
    private let pausedRequests: Set<Int>
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [String] = []
    private(set) var cancelledReturns: Set<Int> = []

    init(responses: [String: [String]], pausedRequests: Set<Int> = []) {
        self.responses = responses
        self.pausedRequests = pausedRequests
    }

    func fetch(_ file: ZoomRecordingFile) async throws -> String {
        calls.append(file.id)
        let request = calls.count
        guard var remaining = responses[file.id], !remaining.isEmpty else { throw TranscriptModelFixtureError.unexpectedFetch }
        let text = remaining.removeFirst()
        responses[file.id] = remaining
        if pausedRequests.contains(request) { await withCheckedContinuation { gates[request] = $0 } }
        if Task.isCancelled { cancelledReturns.insert(request) }
        return text
    }

    func isPaused(_ request: Int) -> Bool { gates[request] != nil }
    func resume(_ request: Int) { gates.removeValue(forKey: request)?.resume() }
}
