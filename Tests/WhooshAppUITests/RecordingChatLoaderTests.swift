import Foundation
import Synchronization
import Testing
@testable import WhooshAppUI

@Suite("Recording chat transport", .serialized)
struct RecordingChatLoaderTests {
    @Test func downloadsUnicodeTextUsingBearerHeadersAndRefreshesOnlyOnce() async throws {
        let calls = Mutex<[Bool]>([])
        let requests = Mutex<[URLRequest]>([])
        let expected = "00:00:12\tZoë:\tHello, 世界!\n"
        RecordingChatURLProtocol.handler.withLock { value in
            value = { request in
                requests.withLock { $0.append(request) }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                    return (chatResponse(401, headers: ["Content-Type": "text/html"]), Data("Sign in".utf8))
                }
                let data = Data([0xEF, 0xBB, 0xBF]) + Data(expected.utf8)
                return (chatResponse(200, headers: ["Content-Length": String(data.count)]), data)
            }
        }
        defer { RecordingChatURLProtocol.handler.withLock { $0 = nil } }
        let text = try await RecordingChatLoader.load(configuration: configuration()) { refresh in
            calls.withLock { $0.append(refresh) }
            var request = URLRequest(url: URL(string: "https://zoom.us/chat")!)
            request.setValue(refresh ? "Bearer current" : "Bearer expired", forHTTPHeaderField: "Authorization")
            return request
        }
        #expect(text == expected)
        #expect(calls.withLock { $0 } == [false, true])
        #expect(requests.withLock { $0.count } == 2)
        #expect(requests.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil } })
        #expect(requests.withLock { $0.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" } })
    }

    @Test func aSecondAuthorizationFailureEndsWithoutARefreshLoop() async {
        let calls = Mutex<[Bool]>([])
        RecordingChatURLProtocol.handler.withLock { value in
            value = { _ in (chatResponse(401), Data()) }
        }
        defer { RecordingChatURLProtocol.handler.withLock { $0 = nil } }
        await #expect(throws: RecordingChatError.unauthorized) {
            try await RecordingChatLoader.load(configuration: configuration()) { refresh in
                calls.withLock { $0.append(refresh) }
                return URLRequest(url: URL(string: "https://zoom.us/chat")!)
            }
        }
        #expect(calls.withLock { $0 } == [false, true])
    }

    @Test func rejectsOversizedHeadersAndBodiesEvenWhenLengthIsUnknown() async {
        for headers in [["Content-Length": "17"], [:]] {
            RecordingChatURLProtocol.handler.withLock { value in
                value = { _ in (chatResponse(200, headers: headers), Data(repeating: 65, count: 17)) }
            }
            await #expect(throws: RecordingChatError.tooLarge) {
                try await RecordingChatLoader.load(configuration: configuration(), byteLimit: 16) { _ in
                    URLRequest(url: URL(string: "https://zoom.us/chat")!)
                }
            }
        }
        RecordingChatURLProtocol.handler.withLock { $0 = nil }
        #expect(throws: RecordingChatError.tooLarge) {
            try RecordingChatLoader.checkResponse(chatResponse(200, headers: [
                "Content-Length": String(RecordingChatLoader.maximumByteCount + 1)
            ]))
        }
    }

    @Test func rejectsTruncatedBodiesAndUnrequestedPartialResponses() async {
        RecordingChatURLProtocol.handler.withLock { value in
            value = { _ in (chatResponse(200, headers: ["Content-Length": "8"]), Data("short".utf8)) }
        }
        defer { RecordingChatURLProtocol.handler.withLock { $0 = nil } }
        await #expect(throws: RecordingChatError.incompleteDownload) {
            try await RecordingChatLoader.load(configuration: configuration()) { _ in
                URLRequest(url: URL(string: "https://zoom.us/chat")!)
            }
        }
        #expect(throws: RecordingChatError.invalidResponse) {
            try RecordingChatLoader.checkResponse(chatResponse(206, headers: ["Content-Range": "bytes 0-4/20"]))
        }
    }

    @Test func decodesUTF16WithBOMOrAnExplicitCharset() throws {
        let expected = "00:00:01\tRenée:\tHello 👋\r\n"
        let littleEndian = try #require(expected.data(using: .utf16LittleEndian))
        let bigEndian = try #require(expected.data(using: .utf16BigEndian))
        #expect(try RecordingChatLoader.decode(Data([0xFF, 0xFE]) + littleEndian) == expected)
        #expect(try RecordingChatLoader.decode(Data([0xFE, 0xFF]) + bigEndian) == expected)
        #expect(try RecordingChatLoader.decode(littleEndian, charset: "UTF-16LE") == expected)
        #expect(try RecordingChatLoader.decode(bigEndian, charset: "UTF-16BE") == expected)
        #expect(try RecordingChatLoader.decode(Data()) == "")
    }

    @Test func rejectsHTMLAuthenticationPagesBinaryDataAndUnsupportedEncoding() {
        #expect(throws: RecordingChatError.unsupportedContent) {
            try RecordingChatLoader.checkResponse(chatResponse(200, headers: ["Content-Type": "text/html"]))
        }
        for text in [" \n<!DOCTYPE html><html>Sign in</html>", "<html>Sign in</html>",
                     "<?xml version=\"1.0\"?><Error>AccessDenied</Error>", "abc\0binary"] {
            #expect(throws: RecordingChatError.unsupportedContent) {
                try RecordingChatLoader.decode(Data(text.utf8))
            }
        }
        #expect(throws: RecordingChatError.invalidEncoding) {
            try RecordingChatLoader.decode(Data([0xFF, 0x80, 0x80]))
        }
        #expect(throws: RecordingChatError.invalidResponse) {
            try RecordingChatLoader.checkResponse(chatResponse(200, headers: ["Content-Encoding": "gzip"]))
        }
    }

    @Test func permissionAndRateLimitFailuresRemainActionable() {
        for (status, error) in [(403, RecordingChatError.forbidden), (429, .rateLimited), (500, .rejected(500))] {
            #expect(throws: error) { try RecordingChatLoader.checkResponse(chatResponse(status)) }
        }
        #expect(throws: RecordingChatError.rejected(302)) {
            try RecordingChatLoader.checkResponse(chatResponse(302))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsTheTextTransfer() async throws {
        let started = Mutex(false)
        RecordingChatURLProtocol.stopped.withLock { $0 = 0 }
        RecordingChatURLProtocol.holdBody.withLock { $0 = true }
        RecordingChatURLProtocol.handler.withLock { value in
            value = { _ in
                started.withLock { $0 = true }
                return (chatResponse(200, headers: ["Content-Length": "20"]), Data())
            }
        }
        defer {
            RecordingChatURLProtocol.handler.withLock { $0 = nil }
            RecordingChatURLProtocol.holdBody.withLock { $0 = false }
        }
        let operation = Task {
            try await RecordingChatLoader.load(configuration: configuration()) { _ in
                URLRequest(url: URL(string: "https://zoom.us/chat")!)
            }
        }
        for _ in 0..<100 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        for _ in 0..<100 {
            if RecordingChatURLProtocol.stopped.withLock({ $0 > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started.withLock { $0 })
        #expect(RecordingChatURLProtocol.stopped.withLock { $0 } > 0)
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = RecordingMediaHTTP.sessionConfiguration()
        configuration.protocolClasses = [RecordingChatURLProtocol.self]
        return configuration
    }
}

private func chatResponse(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://zoom.us/chat")!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"].merging(headers) { _, value in value })!
}

private final class RecordingChatURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) -> (HTTPURLResponse, Data))?>(nil)
    static let holdBody = Mutex(false)
    static let stopped = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = respond(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.holdBody.withLock({ $0 }) { return }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped.withLock { $0 += 1 } }
}
