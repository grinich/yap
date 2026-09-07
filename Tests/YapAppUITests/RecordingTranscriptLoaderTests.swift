import Foundation
import Synchronization
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Recording transcript transport", .serialized)
struct RecordingTranscriptLoaderTests {
    @Test func loadsVTTWithBearerAuthorizationAndOneRefreshWithoutRequestingVideoRanges() async throws {
        let attempts = Mutex<[Bool]>([])
        let requests = Mutex<[URLRequest]>([])
        let expected = "WEBVTT\r\n\r\n1\r\n00:00:01.200 --> 00:00:03.400\r\nZoë: Hello, 世界!\r\n"
        RecordingTranscriptURLProtocol.handler.withLock { value in
            value = { request in
                requests.withLock { $0.append(request) }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                    return (transcriptResponse(401, headers: ["Content-Type": "text/html"]), Data("Sign in".utf8))
                }
                let data = Data([0xEF, 0xBB, 0xBF]) + Data(expected.utf8)
                return (transcriptResponse(200, headers: ["Content-Length": String(data.count)]), data)
            }
        }
        defer { RecordingTranscriptURLProtocol.handler.withLock { $0 = nil } }
        let text = try await RecordingTranscriptLoader.load(configuration: configuration()) { refresh in
            attempts.withLock { $0.append(refresh) }
            var request = URLRequest(url: URL(string: "https://zoom.us/transcript")!)
            request.setValue(refresh ? "Bearer current" : "Bearer expired", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            return request
        }
        #expect(text == expected)
        #expect(attempts.withLock { $0 } == [false, true])
        #expect(requests.withLock { $0.count } == 2)
        #expect(requests.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "Accept")?.contains("text/vtt") == true } })
        #expect(requests.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil } })
        #expect(requests.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" } })
    }

    @Test(arguments: [(401, RecordingTranscriptError.unauthorized), (403, .forbidden),
                      (429, .rateLimited), (500, .rejected(500))])
    func returnsTranscriptSpecificErrorsAndNeverRefreshesMoreThanOnce(status: Int, expected: RecordingTranscriptError) async {
        let attempts = Mutex<[Bool]>([])
        RecordingTranscriptURLProtocol.handler.withLock { value in
            value = { _ in (transcriptResponse(status), Data()) }
        }
        defer { RecordingTranscriptURLProtocol.handler.withLock { $0 = nil } }
        await #expect(throws: expected) {
            try await RecordingTranscriptLoader.load(configuration: configuration()) { refresh in
                attempts.withLock { $0.append(refresh) }
                return URLRequest(url: URL(string: "https://zoom.us/transcript")!)
            }
        }
        #expect(attempts.withLock { $0 } == (status == 401 ? [false, true] : [false]))
        #expect(expected.localizedDescription.lowercased().contains("transcript"))
    }

    @Test(arguments: ["text/vtt", "text/plain", "application/octet-stream", "binary/octet-stream"])
    func acceptsTranscriptDownloadMIMETypesAndUTF16BOM(mime: String) async throws {
        let expected = "WEBVTT\n\n00:01.000 --> 00:02.000\nRenée: Hello 👋\n"
        let encoded = try #require(expected.data(using: .utf16LittleEndian))
        RecordingTranscriptURLProtocol.handler.withLock { value in
            value = { _ in (transcriptResponse(200, headers: ["Content-Type": mime]), Data([0xFF, 0xFE]) + encoded) }
        }
        defer { RecordingTranscriptURLProtocol.handler.withLock { $0 = nil } }
        #expect(try await loadFixture() == expected)
    }

    @Test func rejectsHTMLAuthenticationPagesAndNonTextMedia() async {
        for mime in ["text/html", "application/json", "video/mp4"] {
            RecordingTranscriptURLProtocol.handler.withLock { value in
                value = { _ in (transcriptResponse(200, headers: ["Content-Type": mime]), Data("WEBVTT".utf8)) }
            }
            await #expect(throws: RecordingTranscriptError.unsupportedContent) { try await loadFixture() }
        }
        for text in [" \n<!DOCTYPE html><html>Sign in</html>", "<html>Sign in</html>",
                     "<?xml version=\"1.0\"?><Error>AccessDenied</Error>", "WEBVTT\0binary"] {
            RecordingTranscriptURLProtocol.handler.withLock { value in
                value = { _ in (transcriptResponse(200), Data(text.utf8)) }
            }
            await #expect(throws: RecordingTranscriptError.unsupportedContent) { try await loadFixture() }
        }
        RecordingTranscriptURLProtocol.handler.withLock { $0 = nil }
    }

    @Test func enforcesActualAndDeclaredBoundsAndRejectsIncompleteTransfers() async {
        let cases: [(HTTPURLResponse, Data, RecordingTranscriptError)] = [
            (transcriptResponse(200, headers: ["Content-Length": "17"]), Data("WEBVTT".utf8), .tooLarge),
            (transcriptResponse(200), Data(repeating: 65, count: 17), .tooLarge),
            (transcriptResponse(200, headers: ["Content-Length": "10"]), Data("WEBVTT".utf8), .incompleteDownload),
            (transcriptResponse(206, headers: ["Content-Range": "bytes 0-5/20"]), Data("WEBVTT".utf8), .invalidResponse),
            (transcriptResponse(200, headers: ["Content-Encoding": "gzip"]), Data(), .invalidResponse),
            (transcriptResponse(200), Data([0xFF, 0x80, 0x80]), .invalidEncoding)
        ]
        for (response, body, expected) in cases {
            RecordingTranscriptURLProtocol.handler.withLock { value in value = { _ in (response, body) } }
            await #expect(throws: expected) { try await loadFixture(byteLimit: 16) }
        }
        RecordingTranscriptURLProtocol.handler.withLock { $0 = nil }
    }

    @Test func rejectsVideoAndOversizedTranscriptBeforeReadingCredentials() async {
        let client = ZoomAccountClient(store: TranscriptUnusedStore())
        let video = ZoomRecordingFile(id: "video", recordingType: "gallery_view", fileType: "MP4", fileSize: 10,
            downloadURL: URL(string: "https://zoom.us/rec/download/video"), playURL: nil, status: "completed")
        await #expect(throws: RecordingTranscriptError.unsupportedContent) {
            try await RecordingTranscriptLoader.load(client: client, file: video)
        }
        let oversized = ZoomRecordingFile(id: "transcript", recordingType: "audio_transcript", fileType: "TRANSCRIPT",
            fileSize: Int64(RecordingTranscriptLoader.maximumByteCount + 1),
            downloadURL: URL(string: "https://zoom.us/rec/download/transcript"), playURL: nil, status: "completed")
        await #expect(throws: RecordingTranscriptError.tooLarge) {
            try await RecordingTranscriptLoader.load(client: client, file: oversized)
        }
    }

    @Test func preservesCancellationFromTheRequestProvider() async {
        await #expect(throws: CancellationError.self) {
            try await RecordingTranscriptLoader.load(configuration: configuration()) { _ in throw CancellationError() }
        }
    }

    private func loadFixture(byteLimit: Int = RecordingTranscriptLoader.maximumByteCount) async throws -> String {
        try await RecordingTranscriptLoader.load(configuration: configuration(), byteLimit: byteLimit) { _ in
            URLRequest(url: URL(string: "https://zoom.us/transcript")!)
        }
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = RecordingMediaHTTP.sessionConfiguration()
        configuration.protocolClasses = [RecordingTranscriptURLProtocol.self]
        return configuration
    }
}

private func transcriptResponse(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://zoom.us/transcript")!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/vtt; charset=utf-8"].merging(headers) { _, value in value })!
}

private final class RecordingTranscriptURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) -> (HTTPURLResponse, Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = respond(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor TranscriptUnusedStore: ZoomCredentialStore {
    func loadConfiguration() -> ZoomPersonalConfiguration? { nil }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) {}
    func loadTokens() -> ZoomOAuthTokens? { nil }
    func saveTokens(_ value: ZoomOAuthTokens) {}
    func deleteTokens() {}
    func deleteAll() {}
}
