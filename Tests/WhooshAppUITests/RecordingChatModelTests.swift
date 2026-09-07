import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Recorded chat synchronization") @MainActor
struct RecordingChatModelTests {
    @Test func mapsMeetingClockToSegmentBoundsAndFallsBackWhenStartIsMissing() throws {
        let model = RecordingChatModel(fetch: { _ in throw ChatModelFixtureError.unexpectedFetch })
        let meeting = meeting("meeting")
        model.select(meeting, isPreview: false)
        let video = video(start: meeting.startTime.addingTimeInterval(300),
                          end: meeting.startTime.addingTimeInterval(600))
        model.synchronize(playerTime: 30, file: video, duration: 120)

        #expect(model.playbackTime(for: message(offset: 299)) == nil)
        #expect(model.playbackTime(for: message(offset: 300)) == 0)
        #expect(model.playbackTime(for: message(offset: 330)) == 30)
        let lastMoment = try #require(model.playbackTime(for: message(offset: 419.999)))
        #expect(abs(lastMoment - 119.999) < 0.000_001)
        #expect(model.playbackTime(for: message(offset: 420)) == nil)
        #expect(model.timingNotice != nil)

        model.synchronize(playerTime: 30, file: self.video(), duration: 600)
        #expect(model.playbackTime(for: message(offset: 330)) == 330)
        #expect(model.timingNotice == nil)
        model.synchronize(playerTime: .infinity, file: video, duration: 120)
        #expect(model.playbackTime(for: message(offset: 330)) == nil)
        #expect(model.activeMessageIDs.isEmpty)
        #expect(model.scrollTargetID == nil)
    }

    @Test func forwardAndBackwardSeeksHighlightTheLatestSimultaneousGroup() async throws {
        let fixture = ChatModelFixture(responses: ["chat": [
            "00:00:05\tSam: First\n00:00:10\tAda: Together\n00:00:10\tLin: Same time\n00:00:20\tSam: Last"
        ]])
        let model = makeModel(fixture)
        model.select(meeting("meeting", chats: [chat("chat")]), isPreview: false)
        model.setPresented(true)
        try await waitUntil { model.hasLoaded || model.error != nil }
        #expect(model.error == nil)
        let first = try #require(model.messages.first(where: { $0.text == "First" }))
        let together = model.messages.filter { $0.offset == 10 }
        let last = try #require(model.messages.first(where: { $0.text == "Last" }))
        #expect(together.count == 2)

        model.synchronize(playerTime: 9, file: video(), duration: 60)
        #expect(model.activeMessageIDs == [first.id])
        model.synchronize(playerTime: 10, file: video(), duration: 60)
        #expect(model.activeMessageIDs == Set(together.map(\.id)))
        #expect(model.scrollTargetID == together.last?.id)
        model.synchronize(playerTime: 30, file: video(), duration: 60)
        #expect(model.activeMessageIDs == [last.id])
        model.synchronize(playerTime: 4, file: video(), duration: 60)
        #expect(model.activeMessageIDs.isEmpty)
        #expect(model.scrollTargetID == nil)
        model.followsPlayback = false
        model.synchronize(playerTime: 10, file: video(), duration: 60)
        #expect(model.activeMessageIDs == Set(together.map(\.id)))
        #expect(!model.followsPlayback)
    }

    @Test func loadsOnlyWhenOpenedAndReusesChatOnReopen() async throws {
        let fixture = ChatModelFixture(responses: ["chat": ["00:00:01\tAda: Hello"]])
        let model = makeModel(fixture)
        let selected = meeting("meeting", chats: [chat("chat")])
        model.select(selected, isPreview: false)
        model.synchronize(playerTime: 1, file: video(), duration: 60)
        #expect(model.hasChatFile)
        #expect(!model.hasLoaded)
        #expect(await fixture.calls.isEmpty)

        model.setPresented(true)
        try await waitUntil { model.hasLoaded || model.error != nil }
        #expect(model.error == nil)
        let loadedMessages = model.messages
        #expect(loadedMessages.count == 1)
        #expect(model.activeMessageIDs == Set(loadedMessages.map(\.id)))
        model.setPresented(false)
        model.select(selected, isPreview: false)
        model.setPresented(true)
        #expect(model.messages == loadedMessages)
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(await fixture.calls == ["chat"])
    }

    @Test(arguments: [RecordingChatAvailability.noFile, .emptyFile, .preview])
    func emptyAndPreviewStatesAvoidUnnecessaryRequests(_ availability: RecordingChatAvailability) async throws {
        let fixture = ChatModelFixture(responses: ["chat": [" \n\t\n"]])
        let model = makeModel(fixture)
        model.select(meeting("meeting", chats: availability == .noFile ? [] : [chat("chat")]),
                     isPreview: availability == .preview)
        model.setPresented(true)
        try await waitUntil { model.hasLoaded || model.error != nil }

        #expect(model.error == nil)
        #expect(!model.isLoading)
        #expect(model.hasChatFile == (availability != .noFile))
        #expect(model.messages.isEmpty == (availability != .preview))
        #expect(await fixture.calls.count == (availability == .emptyFile ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func cancelledAccountResultsCannotPopulateOrFinishANewerChat(replaceMeeting: Bool) async throws {
        let fixture = ChatModelFixture(responses: [
            "old-chat": ["00:00:01\tOld account: Private old content"],
            "new-chat": ["00:00:02\tNew account: Current content"]
        ], pausedRequests: [1, 2])
        let model = makeModel(fixture)
        defer { model.clear() }
        model.select(meeting("old", chats: [chat("old-chat")]), isPreview: false)
        model.setPresented(true)
        try await waitUntil { await fixture.isPaused(1) }

        if replaceMeeting {
            model.select(meeting("new", chats: [chat("new-chat")]), isPreview: false)
            try await waitUntil { await fixture.isPaused(2) }
        } else { model.clear() }
        await fixture.resume(1)
        try await waitUntil { await fixture.returnedRequests.contains(1) }
        // Let the canceled fetch's continuation reach the main actor before
        // inspecting the still-pending new account (or cleared account).
        await Task.yield()
        await Task.yield()
        #expect(await fixture.cancelledReturns.contains(1))
        #expect(model.messages.isEmpty)
        #expect(!model.hasLoaded)
        #expect(model.isLoading == replaceMeeting)
        #expect(model.isPresented == replaceMeeting)
        #expect(model.error == nil)
        #expect(model.activeMessageIDs.isEmpty)

        if replaceMeeting {
            await fixture.resume(2)
            try await waitUntil { model.hasLoaded || model.error != nil }
            #expect(model.messages.map(\.text) == ["Current content"])
            #expect(model.error == nil)
            #expect(!model.isLoading)
        }
    }

    @Test func overlappingChatFilesDeduplicateCopiesButKeepRepeatedMessagesWithinAFile() async throws {
        let fixture = ChatModelFixture(responses: [
            "first": ["00:00:10\tAda: Yes\n00:00:10\tAda: Yes\n00:00:20\tLin: Later"],
            "second": ["00:00:10\tAda: Yes\n00:00:10\tAda: Yes\n00:00:05\tSam: Earlier\n00:00:10\tFrom Ada to Everyone:\tYes"]
        ])
        let model = makeModel(fixture)
        model.select(meeting("meeting", chats: [chat("first"), chat("second")]), isPreview: false)
        model.setPresented(true)
        try await waitUntil { model.hasLoaded || model.error != nil }

        #expect(model.error == nil)
        #expect(await fixture.calls == ["first", "second"])
        #expect(model.messages.map(\.offset) == [5, 10, 10, 10, 20])
        #expect(model.messages.filter { $0.sender == "Ada" && $0.recipient == nil }.count == 2)
        #expect(model.messages.filter { $0.recipient == "Everyone" }.count == 1)
        #expect(Set(model.messages.map(\.id)).count == 5)
        #expect(model.messages.first?.text == "Earlier")
        #expect(model.messages.last?.text == "Later")
    }

    @Test func aDedicatedPlayerAdoptsLoadedChatButKeepsItsOwnClockAndLifetime() async throws {
        let fixture = ChatModelFixture(responses: ["chat": ["00:00:05\tAda: First\n00:00:20\tLin: Later"]])
        let source = makeModel(fixture)
        let selected = meeting("meeting", chats: [chat("chat")])
        source.select(selected, isPreview: false)
        source.setPresented(true)
        try await waitUntil { source.hasLoaded || source.error != nil }
        #expect(source.error == nil)
        source.synchronize(playerTime: 5, file: video(), duration: 60)
        source.followsPlayback = false
        let sourceHighlight = source.activeMessageIDs
        let loadedMessages = source.messages

        let childFixture = ChatModelFixture(responses: [:])
        let child = makeModel(childFixture)
        child.select(selected, isPreview: false)
        child.adoptState(from: source)
        #expect(child.isPresented)
        #expect(child.hasLoaded)
        #expect(child.messages == loadedMessages)
        #expect(!child.followsPlayback)
        child.synchronize(playerTime: 20, file: video(), duration: 60)
        #expect(child.activeMessageIDs == Set(loadedMessages.filter { $0.offset == 20 }.map(\.id)))
        #expect(source.activeMessageIDs == sourceHighlight)
        source.clear()
        #expect(child.messages == loadedMessages)
        #expect(child.isPresented)
        #expect(child.hasLoaded)
        #expect(await childFixture.calls.isEmpty)
        child.clear()
    }

    @Test func unreadableContentOffersRetryAndDoesNotBecomeACachedEmptyChat() async throws {
        let fixture = ChatModelFixture(responses: ["chat": ["Unsupported chat content", "00:00:01\tAda: Recovered"]])
        let model = makeModel(fixture)
        model.select(meeting("meeting", chats: [chat("chat")]), isPreview: false)
        model.setPresented(true)
        try await waitUntil { model.error != nil }
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.messages.isEmpty)

        model.retry()
        try await waitUntil { model.hasLoaded || model.error != nil }
        #expect(model.error == nil)
        #expect(model.messages.map(\.text) == ["Recovered"])
        #expect(await fixture.calls == ["chat", "chat"])
    }

    private func makeModel(_ fixture: ChatModelFixture) -> RecordingChatModel {
        RecordingChatModel(fetch: { try await fixture.fetch($0) })
    }

    private func meeting(_ id: String, chats: [ZoomRecordingFile] = []) -> ZoomRecordingMeeting {
        .init(id: id, topic: "Fixture meeting", startTime: Date(timeIntervalSince1970: 1_787_054_400),
              duration: 60, files: chats)
    }

    private func chat(_ id: String) -> ZoomRecordingFile {
        .init(id: id, recordingType: "chat_file", fileType: "CHAT", fileSize: 100,
              downloadURL: URL(string: "https://zoom.us/rec/download/\(id)"), playURL: nil, status: "completed")
    }

    private func video(start: Date? = nil, end: Date? = nil) -> ZoomRecordingFile {
        .init(id: "video", recordingType: "gallery_view", fileType: "MP4", fileSize: 100,
              downloadURL: URL(string: "https://zoom.us/rec/download/video"), playURL: nil, status: "completed",
              recordingStart: start, recordingEnd: end)
    }

    private func message(offset: TimeInterval) -> ZoomRecordingChatMessage {
        .init(id: "fixture-\(offset)", offset: offset, sender: "Ada", text: "Fixture message")
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ChatModelFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

enum RecordingChatAvailability: Sendable { case noFile, emptyFile, preview }
private enum ChatModelFixtureError: Error { case unexpectedFetch, timedOut }

private actor ChatModelFixture {
    private var responses: [String: [String]]
    private let pausedRequests: Set<Int>
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [String] = []
    private(set) var returnedRequests: Set<Int> = []
    private(set) var cancelledReturns: Set<Int> = []

    init(responses: [String: [String]], pausedRequests: Set<Int> = []) {
        self.responses = responses
        self.pausedRequests = pausedRequests
    }

    func fetch(_ file: ZoomRecordingFile) async throws -> String {
        calls.append(file.id)
        let request = calls.count
        guard var remaining = responses[file.id], !remaining.isEmpty else { throw ChatModelFixtureError.unexpectedFetch }
        let text = remaining.removeFirst()
        responses[file.id] = remaining
        if pausedRequests.contains(request) {
            // Deliberately return even after cancellation so the model must
            // reject stale data itself instead of relying on the transport.
            await withCheckedContinuation { gates[request] = $0 }
        }
        if Task.isCancelled { cancelledReturns.insert(request) }
        returnedRequests.insert(request)
        return text
    }

    func isPaused(_ request: Int) -> Bool { gates[request] != nil }
    func resume(_ request: Int) { gates.removeValue(forKey: request)?.resume() }
}
