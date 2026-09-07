import Foundation
import Testing
@testable import WhooshMeetings

@Suite("ZoomRecordings")
struct ZoomRecordingsTests {
    @Test func decodesMeetingOccurrencesAndFiltersPlayableFiles() throws {
        let page = try JSONDecoder().decode(ZoomRecordingPage.self, from: recordingFixture)
        #expect(page.nextPageToken == "next+/=&token")
        let meeting = try #require(page.meetings.first)
        #expect(meeting.id == "unique/occurrence==")
        #expect(meeting.topic == "Design review")
        #expect(meeting.startTime == Date(timeIntervalSince1970: 1_787_054_400.125))
        #expect(meeting.duration == 42)
        #expect(meeting.files.count == 5)
        #expect(meeting.playableVideoFiles.map(\.id) == ["video"])
        #expect(meeting.playableVideoFiles.first?.fileSize == 5_368_709_120)
        #expect(meeting.playableVideoFiles.first?.displayName == "Screen and speaker")
    }

    @Test func supportsPlainDatesAndOptionalRecordingFields() throws {
        let data = Data(#"{"meetings":[{"uuid":"meeting","start_time":"2026-08-18T12:00:00Z","recording_files":[{"id":"processing"}]}]}"#.utf8)
        let page = try JSONDecoder().decode(ZoomRecordingPage.self, from: data)
        #expect(page.nextPageToken.isEmpty)
        #expect(page.meetings.first?.topic == "Zoom recording")
        #expect(page.meetings.first?.duration == 0)
        #expect(page.meetings.first?.playableVideoFiles.isEmpty == true)
        #expect(page.meetings.first?.shareURL == nil)
        #expect(page.meetings.first?.shareableURL == nil)
    }

    @Test func decodesAndPrefersMeetingShareLinkPreservingItsPasscode() throws {
        let data = Data(#"""
        {"uuid":"meeting","start_time":"2026-08-18T12:00:00Z","share_url":"https://us02web.zoom.us/rec/share/meeting?pwd=recording-passcode","recording_files":[
          {"id":"video","file_type":"MP4","status":"completed","play_url":"https://zoom.us/rec/play/video","download_url":"https://zoom.us/rec/download/video"}
        ]}
        """#.utf8)
        let meeting = try JSONDecoder().decode(ZoomRecordingMeeting.self, from: data)
        #expect(meeting.shareURL?.absoluteString == "https://us02web.zoom.us/rec/share/meeting?pwd=recording-passcode")
        #expect(meeting.shareableURL == meeting.shareURL)
    }

    @Test func fallsBackToCompletedVideoBrowserLinkWithoutRequiringDownloadAccess() throws {
        let data = Data(#"""
        {"uuid":"meeting","start_time":"2026-08-18T12:00:00Z","recording_files":[
          {"id":"audio","file_type":"M4A","status":"completed","play_url":"https://zoom.us/rec/play/audio"},
          {"id":"pending","file_type":"MP4","status":"processing","play_url":"https://zoom.us/rec/play/pending"},
          {"id":"download-only","file_type":"MP4","status":"completed","download_url":"https://zoom.us/rec/download/video"},
          {"id":"untrusted","file_type":"MP4","status":"completed","play_url":"https://zoom.us.attacker.example/rec/play/video"},
          {"id":"video","file_type":"MP4","status":"completed","play_url":"https://zoom.us/rec/play/video?pwd=passcode"}
        ]}
        """#.utf8)
        let meeting = try JSONDecoder().decode(ZoomRecordingMeeting.self, from: data)
        #expect(meeting.shareURL == nil)
        #expect(meeting.shareableURL?.absoluteString == "https://zoom.us/rec/play/video?pwd=passcode")
    }

    @Test(arguments: [
        "http://zoom.us/rec/share/meeting", "https://zoom.us.attacker.example/rec/share/meeting",
        "https://user:password@zoom.us/rec/share/meeting", "https://zoom.us:444/rec/share/meeting",
        "https://zoom.us/rec/download/video", "https://zoom.us/rec/share/meeting?access_token=secret",
        "https://zoom.us/rec/share/meeting?%41CCESS_TOKEN=secret", "https://zoom.us/rec/play/video?download_access_token=secret",
        "https://zoom.us/rec/play/video?download_token=secret", "https://zoom.us/rec/share/meeting?tk=registrant-secret",
        "file:///tmp/recording.mp4"
    ]) func rejectsUnsafeShareAndPlaybackLinks(value: String) throws {
        let url = try #require(URL(string: value))
        let file = ZoomRecordingFile(id: "video", recordingType: "active_speaker", fileType: "MP4", fileSize: 10,
            downloadURL: URL(string: "https://zoom.us/rec/download/video"), playURL: url, status: "completed")
        let meeting = ZoomRecordingMeeting(id: "meeting", topic: "Meeting", startTime: Date(), duration: 1,
            files: [file], shareURL: url)
        #expect(meeting.shareURL == nil)
        #expect(meeting.shareableURL == nil)

        let data = try JSONSerialization.data(withJSONObject: [
            "uuid": "meeting", "start_time": "2026-08-18T12:00:00Z", "share_url": value
        ])
        let decoded = try JSONDecoder().decode(ZoomRecordingMeeting.self, from: data)
        #expect(decoded.shareURL == nil)
        #expect(decoded.shareableURL == nil)
    }

    @Test func decodesOptionalRecordingTimesAndFindsOnlyCompletedTrustedChatFiles() throws {
        let data = Data(#"""
        {"uuid":"meeting","start_time":"2026-08-18T12:00:00Z","recording_files":[
          {"id":"chat","file_type":"CHAT","status":"completed","recording_start":"2026-08-18T12:05:00.125Z","recording_end":"2026-08-18T12:30:00Z","download_url":"https://us02web.zoom.us/rec/download/chat"},
          {"id":"chat-kind","file_type":"TXT","recording_type":"chat_file","status":"completed","recording_start":"invalid","download_url":"https://zoom.us/rec/download/chat2"},
          {"id":"chat-pending","file_type":"CHAT","status":"processing","download_url":"https://zoom.us/rec/download/chat3"},
          {"id":"chat-untrusted","file_type":"CHAT","status":"completed","download_url":"https://attacker.example/chat"},
          {"id":"transcript","file_type":"TRANSCRIPT","status":"completed","download_url":"https://zoom.us/rec/download/transcript"}
        ]}
        """#.utf8)
        let meeting = try JSONDecoder().decode(ZoomRecordingMeeting.self, from: data)
        #expect(meeting.chatFiles.map(\.id) == ["chat", "chat-kind"])
        #expect(meeting.playableVideoFiles.isEmpty)
        #expect(meeting.files[0].recordingStart?.timeIntervalSince(meeting.startTime) == 300.125)
        #expect(meeting.files[0].recordingEnd?.timeIntervalSince(meeting.startTime) == 1_800)
        #expect(meeting.files[1].recordingStart == nil)
        #expect(meeting.files[1].recordingEnd == nil)
    }

    @Test func authorizesCompletedChatUsingExistingZoomCredentials() async throws {
        let server = RecordingFixtureServer()
        let client = makeClient(server: server)
        let file = ZoomRecordingFile(id: "chat", recordingType: "chat_file", fileType: "CHAT", fileSize: 120,
            downloadURL: URL(string: "https://us02web.zoom.us/rec/download/chat"), playURL: nil, status: "completed")
        let request = try await client.recordingMediaRequest(for: file)
        #expect(request.url == file.downloadURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.httpShouldHandleCookies)
        #expect(await server.requests.isEmpty)
    }

    @Test func validatesZoomMediaHostsWithoutSuffixOrCredentialTricks() throws {
        for value in ["https://zoom.us/rec/download/video", "https://us02web.zoom.us/rec/download/video?download=1",
                      "https://us06web.zoom.com:443/rec/download/video"] {
            #expect(ZoomRecordingFile.isTrustedMediaURL(try #require(URL(string: value))))
        }
        for value in ["http://zoom.us/rec/download/video", "https://zoom.us.attacker.example/video",
                      "https://notzoom.us/video", "https://zoom.us@attacker.example/video",
                      "https://user:password@zoom.us/video", "https://zoom.us:444/video",
                      "https://attacker.example/video", "file:///tmp/video.mp4", "https://zoom.us/video#fragment"] {
            #expect(!ZoomRecordingFile.isTrustedMediaURL(try #require(URL(string: value))))
        }
    }

    @Test func listRequestPreservesUTCDateRangeAndOpaquePaginationToken() async throws {
        let server = RecordingFixtureServer()
        let client = makeClient(server: server)
        let from = try date("2026-08-01T00:30:00+02:00")
        let to = try date("2026-08-30T23:59:59Z")
        let page = try await client.recordings(from: from, to: to, nextPageToken: "opaque+/=&token")
        #expect(page.meetings.count == 1)
        let request = try #require(await server.requests.first)
        #expect(request.url?.path == "/v2/users/me/recordings")
        #expect(request.url?.absoluteString.contains("opaque%2B") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        let requestURL = try #require(request.url)
        let query = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first(where: { $0.name == "from" })?.value == "2026-07-31")
        #expect(query.first(where: { $0.name == "to" })?.value == "2026-08-30")
        #expect(query.first(where: { $0.name == "page_size" })?.value == "100")
        #expect(query.first(where: { $0.name == "next_page_token" })?.value == "opaque+/=&token")
    }

    @Test func rejectsReversedAndOversizedRangesBeforeRequestingCredentials() async throws {
        let server = RecordingFixtureServer()
        let client = makeClient(server: server)
        let first = try date("2026-08-01T00:00:00Z")
        let later = try date("2026-09-02T00:00:00Z")
        await #expect(throws: ZoomAccountError.invalidRecordingDateRange) { try await client.recordings(from: first, to: later) }
        await #expect(throws: ZoomAccountError.invalidRecordingDateRange) { try await client.recordings(from: later, to: first) }
        #expect(await server.requests.isEmpty)
    }

    @Test func refreshesOnceOnUnauthorizedAndRetriesSamePage() async throws {
        let server = RecordingFixtureServer(listStatuses: [401, 200])
        let store = RecordingMemoryStore()
        let client = makeClient(server: server, store: store)
        _ = try await client.recordings(from: try date("2026-08-01T00:00:00Z"), to: try date("2026-08-31T00:00:00Z"), nextPageToken: "cursor")
        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == ["/v2/users/me/recordings", "/oauth/token", "/v2/users/me/recordings"])
        #expect(requests.first?.url == requests.last?.url)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        #expect(await store.tokens?.refreshToken == "rotated-refresh")
    }

    @Test func repeatedUnauthorizedDoesNotLoop() async throws {
        let server = RecordingFixtureServer(listStatuses: [401, 401])
        let client = makeClient(server: server)
        let day = try date("2026-08-01T00:00:00Z")
        await #expect(throws: ZoomAccountError.notConnected) { try await client.recordings(from: day, to: day) }
        #expect(await server.requests.count == 3)
    }

    @Test(arguments: [400, 403]) func reportsMissingRecordingScopeWithoutTokenRefresh(status: Int) async throws {
        let server = RecordingFixtureServer(listStatuses: [status], listBody: Data(#"{"code":4711,"message":"provider diagnostic"}"#.utf8))
        let client = makeClient(server: server)
        let day = try date("2026-08-01T00:00:00Z")
        await #expect(throws: ZoomAccountError.missingRecordingScope) { try await client.recordings(from: day, to: day) }
        #expect(await server.requests.count == 1)
        #expect(ZoomAccountError.missingRecordingScope.localizedDescription.contains(ZoomPersonalConfiguration.recordingsScope))
        #expect(!ZoomAccountError.missingRecordingScope.localizedDescription.contains("provider diagnostic"))
    }

    @Test func createsEphemeralAuthorizedMediaRequestAndSupportsForcedRefresh() async throws {
        let server = RecordingFixtureServer()
        let client = makeClient(server: server)
        let file = try #require(JSONDecoder().decode(ZoomRecordingPage.self, from: recordingFixture).meetings.first?.playableVideoFiles.first)
        let initial = try await client.recordingMediaRequest(for: file)
        #expect(initial.url == file.downloadURL)
        #expect(initial.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(initial.url?.absoluteString.contains("fixture-access") == false)
        #expect(initial.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!initial.httpShouldHandleCookies)
        #expect(await server.requests.isEmpty)
        let refreshed = try await client.recordingMediaRequest(for: file, forceRefresh: true)
        #expect(refreshed.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
        #expect(await server.requests.map { $0.url?.path } == ["/oauth/token"])
    }

    @Test func neverAuthorizesUntrustedOrUnfinishedMedia() async throws {
        let server = RecordingFixtureServer()
        let client = makeClient(server: server)
        for file in try JSONDecoder().decode(ZoomRecordingPage.self, from: recordingFixture).meetings[0].files where file.id != "video" {
            await #expect(throws: ZoomAccountError.recordingUnavailable) { try await client.recordingMediaRequest(for: file) }
        }
        #expect(await server.requests.isEmpty)
    }

    @Test(arguments: [false, true]) func discardsDelayedListingAfterCancellationOrDisconnect(disconnect: Bool) async throws {
        let server = RecordingFixtureServer(suspendList: true)
        let client = makeClient(server: server)
        let day = try date("2026-08-01T00:00:00Z")
        let task = Task { try await client.recordings(from: day, to: day) }
        await server.waitForRequest()
        if disconnect { try await client.disconnect() }
        else { task.cancel() }
        await server.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await server.requests.count == 1)
    }

    @Test func mapsMalformedSuccessfulResponseToSafeError() async throws {
        let server = RecordingFixtureServer(listBody: Data(#"{"meetings":[{"uuid":"x","start_time":"invalid"}]}"#.utf8))
        let client = makeClient(server: server)
        let day = try date("2026-08-01T00:00:00Z")
        await #expect(throws: ZoomAccountError.invalidResponse) { try await client.recordings(from: day, to: day) }
    }

    private func makeClient(server: RecordingFixtureServer, store: RecordingMemoryStore = RecordingMemoryStore()) -> ZoomAccountClient {
        ZoomAccountClient(store: store, transport: ZoomHTTPTransport { try await server.send($0) })
    }

    private func date(_ value: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: value)) }
}

private let recordingFixture = Data(#"""
{"next_page_token":"next+/=&token","meetings":[{"uuid":"unique/occurrence==","id":123456789,"topic":"Design review","start_time":"2026-08-18T12:00:00.125Z","duration":42,"recording_files":[
  {"id":"video","recording_type":"shared_screen_with_speaker_view","file_type":"MP4","file_size":5368709120,"status":"completed","download_url":"https://us02web.zoom.us/rec/download/video?download=1","play_url":"https://us02web.zoom.us/rec/play/video"},
  {"id":"audio","file_type":"M4A","status":"completed","download_url":"https://us02web.zoom.us/rec/download/audio"},
  {"id":"processing","file_type":"MP4","status":"processing","download_url":"https://us02web.zoom.us/rec/download/pending"},
  {"id":"untrusted","file_type":"MP4","status":"completed","download_url":"https://zoom.us.attacker.example/video"},
  {"id":"webpage-only","file_type":"MP4","status":"completed","play_url":"https://us02web.zoom.us/rec/play/video"}
]}]}
"""#.utf8)

private actor RecordingMemoryStore: ZoomCredentialStore {
    var configuration: ZoomPersonalConfiguration? = .init(sdkClientID: "fixture-sdk", sdkClientSecret: "fixture-secret", oauthPublicClientID: "fixture-client")
    var tokens: ZoomOAuthTokens? = .init(clientID: "fixture-client", accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3_600))
    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) { configuration = value }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ value: ZoomOAuthTokens) { tokens = value }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
}

private actor RecordingFixtureServer {
    var requests: [URLRequest] = []
    var listStatuses: [Int]
    let listBody: Data
    let suspendList: Bool
    var gate: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    init(listStatuses: [Int] = [200], listBody: Data = recordingFixture, suspendList: Bool = false) {
        self.listStatuses = listStatuses
        self.listBody = listBody
        self.suspendList = suspendList
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path == "/oauth/token" {
            return (Data(#"{"access_token":"refreshed-access","refresh_token":"rotated-refresh","token_type":"bearer","expires_in":3600,"scope":"user:read:zak cloud_recording:read:list_user_recordings"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if suspendList {
            await withCheckedContinuation { continuation in
                gate = continuation
                started?.resume()
                started = nil
            }
        }
        let status = listStatuses.isEmpty ? 200 : listStatuses.removeFirst()
        return (listBody, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func waitForRequest() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { gate?.resume(); gate = nil }
}
