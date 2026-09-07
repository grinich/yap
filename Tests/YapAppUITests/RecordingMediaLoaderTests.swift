import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import YapAppUI

@Suite("Recording media transport", .serialized)
struct RecordingMediaLoaderTests {
    @Test func validRangesSupportSeekingAndTheFinalPartialChunk() throws {
        let middle = response(status: 206, headers: ["Content-Range": "bytes 512-1023/2000", "Content-Length": "512"])
        #expect(try RecordingMediaHTTP.validateRange(middle, offset: 512, count: 512) ==
            RecordingHTTPRange(start: 512, end: 1023, total: 2000))
        let last = response(status: 206, headers: ["Content-Range": "bytes 1536-1999/2000", "Content-Length": "464"])
        #expect(try RecordingMediaHTTP.validateRange(last, offset: 1536, count: 512).length == 464)
    }

    @Test func fullResponsesRequireDownloadInsteadOfPretendingToSupportSeeks() {
        #expect(throws: RecordingMediaError.streamingUnavailable) {
            try RecordingMediaHTTP.validateRange(response(status: 200, headers: ["Content-Length": "2000"]),
                                                 offset: 512, count: 512)
        }
    }

    @Test func rangeValidationRejectsWrongOffsetsLengthsAndUnknownTotals() {
        let invalid = [
            ["Content-Range": "bytes 0-511/2000", "Content-Length": "512"],
            ["Content-Range": "bytes 512-1023/2000", "Content-Length": "2000"],
            ["Content-Range": "bytes 512-1023/*", "Content-Length": "512"],
            ["Content-Range": "bytes 512-2047/2000", "Content-Length": "1536"],
            ["Content-Range": "bytes 512-1023/1023", "Content-Length": "512"],
            ["Content-Range": "bytes 512-512/2000", "Content-Length": "1"],
            ["Content-Range": "bytes 512-1023/9223372036854775808", "Content-Length": "512"]
        ]
        for headers in invalid {
            #expect(throws: RecordingMediaError.invalidResponse) {
                try RecordingMediaHTTP.validateRange(response(status: 206, headers: headers), offset: 512, count: 512)
            }
        }
    }

    @Test func rejectLoginPagesAndCompressedRanges() {
        #expect(throws: RecordingMediaError.unsupportedContent) {
            try RecordingMediaHTTP.validateRange(response(status: 206, headers: [
                "Content-Type": "text/html", "Content-Range": "bytes 0-1/2000", "Content-Length": "2"
            ]), offset: 0, count: 2)
        }
        #expect(throws: RecordingMediaError.invalidResponse) {
            try RecordingMediaHTTP.validateRange(response(status: 206, headers: [
                "Content-Encoding": "gzip", "Content-Range": "bytes 0-1/2000", "Content-Length": "2"
            ]), offset: 0, count: 2)
        }
        #expect(!RecordingMediaHTTP.isMP4Prefix(Data("<html>Sign in</html>".utf8)))
        #expect(RecordingMediaHTTP.isMP4Prefix(Data([0, 0, 0, 20]) + Data("ftypisom".utf8)))
    }

    @Test func redirectsRetainZoomAuthorizationOnlyWithinZoom() throws {
        var source = URLRequest(url: URL(string: "https://us02web.zoom.us/rec/download/video")!)
        source.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        source.setValue("bytes=500-999", forHTTPHeaderField: "Range")
        for destination in ["https://cdn.example.com/signed?signature=opaque", "https://zoom.us.evil.example/media", "https://evilzoom.us/media"] {
            var proposed = URLRequest(url: URL(string: destination)!)
            proposed.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            proposed.setValue("private=session", forHTTPHeaderField: "Cookie")
            proposed.setValue(source.url!.absoluteString, forHTTPHeaderField: "Referer")
            let redirected = try #require(RecordingMediaHTTP.redirect(proposed, from: source))
            #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(redirected.value(forHTTPHeaderField: "Referer") == nil)
            #expect(redirected.value(forHTTPHeaderField: "Range") == "bytes=500-999")
        }
        let zoomRedirect = try #require(RecordingMediaHTTP.redirect(
            URLRequest(url: URL(string: "https://us04web.zoom.us/rec/download/video")!), from: source))
        #expect(zoomRedirect.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let cdnSource = URLRequest(url: URL(string: "https://cdn.example.com/signed")!)
        #expect(RecordingMediaHTTP.redirect(zoomRedirect, from: cdnSource)?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func redirectsRejectCleartextCredentialsAndUnexpectedPorts() {
        let source = URLRequest(url: URL(string: "https://zoom.us/media")!)
        for destination in ["http://zoom.us/media", "file:///tmp/media", "https://user:password@zoom.us/media", "https://zoom.us:444/media"] {
            #expect(RecordingMediaHTTP.redirect(URLRequest(url: URL(string: destination)!), from: source) == nil)
        }
    }

    @Test func actualTransportUsesBoundedAuthenticatedRangeRequests() async throws {
        let requests = Mutex<[URLRequest]>([])
        RecordingMediaURLProtocol.handler.withLock { value in
            value = { request in
                requests.withLock { $0.append(request) }
                return (response(status: 206, headers: ["Content-Range": "bytes 128-131/1000", "Content-Length": "4"]), Data([1, 2, 3, 4]))
            }
        }
        defer { RecordingMediaURLProtocol.handler.withLock { $0 = nil } }
        let transport = transport()
        defer { transport.invalidate() }
        let chunk = try await transport.range(offset: 128, count: 4)
        #expect(chunk.data == Data([1, 2, 3, 4]))
        #expect(chunk.totalLength == 1000)
        let request = try #require(requests.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=128-131")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(try await transport.range(offset: 128, count: 4).data == Data([1, 2, 3, 4]))
        #expect(try await transport.range(offset: 129, count: 2).data == Data([2, 3]))
        #expect(requests.withLock { $0.count } == 1)
    }

    @Test func rangeCacheJoinsAdjacentRangesAndReturnsTheShortFinalRange() {
        let cache = RecordingMediaRangeCache(byteLimit: 12)
        cache.store(.init(data: Data([0, 1, 2, 3]), totalLength: 12), offset: 0)
        cache.store(.init(data: Data([4, 5, 6, 7]), totalLength: 12), offset: 4)
        #expect(cache.chunk(offset: 2, count: 4)?.data == Data([2, 3, 4, 5]))
        #expect(cache.chunk(offset: 6, count: 5) == nil)
        cache.store(.init(data: Data([8, 9, 10, 11]), totalLength: 12), offset: 8)
        #expect(cache.chunk(offset: 10, count: 512)?.data == Data([10, 11]))
        #expect(cache.chunk(offset: 0, count: 12)?.totalLength == 12)
        #expect(cache.cachedByteCount == 12)
    }

    @Test func rangeCacheEvictsLeastRecentlyUsedDataWithinItsByteBudget() {
        let cache = RecordingMediaRangeCache(byteLimit: 8)
        cache.store(.init(data: Data([0, 1, 2, 3]), totalLength: 16), offset: 0)
        cache.store(.init(data: Data([4, 5, 6, 7]), totalLength: 16), offset: 4)
        #expect(cache.chunk(offset: 0, count: 2) != nil)
        cache.store(.init(data: Data([8, 9, 10, 11]), totalLength: 16), offset: 8)
        #expect(cache.cachedByteCount == 8)
        #expect(cache.chunk(offset: 4, count: 4) == nil)
        #expect(cache.chunk(offset: 0, count: 4)?.data == Data([0, 1, 2, 3]))
        #expect(cache.chunk(offset: 8, count: 4)?.data == Data([8, 9, 10, 11]))
    }

    @Test func rangeCacheSupersedesCoveredHeadersAndDiscardsChangedResources() {
        let cache = RecordingMediaRangeCache(byteLimit: 8)
        cache.store(.init(data: Data([0, 1]), totalLength: 16), offset: 0)
        cache.store(.init(data: Data([0, 1, 2, 3]), totalLength: 16), offset: 0)
        #expect(cache.cachedByteCount == 4)
        cache.store(.init(data: Data([8, 9, 10, 11]), totalLength: 20), offset: 8)
        #expect(cache.cachedByteCount == 4)
        #expect(cache.chunk(offset: 0, count: 2) == nil)
        #expect(cache.chunk(offset: 8, count: 4)?.totalLength == 20)
    }

    @Test func invalidatedRangeCacheCannotBeRepopulatedByLateResponses() {
        let cache = RecordingMediaRangeCache(byteLimit: 8)
        let chunk = RecordingMediaChunk(data: Data([0, 1, 2, 3]), totalLength: 16)
        cache.store(chunk, offset: 0)
        cache.invalidate()
        cache.store(chunk, offset: 0)
        #expect(cache.cachedByteCount == 0)
        #expect(cache.chunk(offset: 0, count: 2) == nil)
    }

    @Test func actualTransportRejectsTruncatedAndOversizedBodies() async throws {
        for body in [Data([1]), Data([1, 2, 3])] {
            RecordingMediaURLProtocol.handler.withLock { value in
                value = { _ in
                    (response(status: 206, headers: ["Content-Range": "bytes 0-1/1000", "Content-Length": "2"]), body)
                }
            }
            let transport = transport()
            defer { transport.invalidate() }
            await #expect(throws: (any Error).self) { try await transport.range(offset: 0, count: 2) }
        }
        RecordingMediaURLProtocol.handler.withLock { $0 = nil }
    }

    @Test func authorizationFailureAndInvalidatedSessionsDoNotSilentlyDownload() async {
        RecordingMediaURLProtocol.handler.withLock { value in
            value = { _ in (response(status: 401, headers: ["Content-Type": "text/html"]), Data()) }
        }
        defer { RecordingMediaURLProtocol.handler.withLock { $0 = nil } }
        let transport = transport()
        await #expect(throws: RecordingMediaError.unauthorized) { try await transport.range(offset: 0, count: 2) }
        transport.invalidate()
        await #expect(throws: (any Error).self) { try await transport.range(offset: 0, count: 2) }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func resourceLoaderDecodesVideoAndRefreshesExpiredAuthorization() async throws {
        let video = Data(base64Encoded: recordingMP4Fixture)!
        let authorizations = Mutex<[Bool]>([])
        let ranges = Mutex<[String]>([])
        RecordingMediaURLProtocol.handler.withLock { value in
            value = { request in
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed" else {
                    return (response(status: 401, headers: [:]), Data())
                }
                let range = request.value(forHTTPHeaderField: "Range") ?? ""
                ranges.withLock { $0.append(range) }
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] >= 0, bounds[0] < video.count else {
                    return (response(status: 416, headers: [:]), Data())
                }
                let start = bounds[0]
                let end = min(bounds[1], video.count - 1)
                return (response(status: 206, headers: [
                    "Content-Range": "bytes \(start)-\(end)/\(video.count)",
                    "Content-Length": String(end - start + 1)
                ]), video.subdata(in: start..<(end + 1)))
            }
        }
        defer { RecordingMediaURLProtocol.handler.withLock { $0 = nil } }
        let configuration = RecordingMediaHTTP.sessionConfiguration()
        configuration.protocolClasses = [RecordingMediaURLProtocol.self]
        let transport = RecordingMediaTransport(configuration: configuration) { forceRefresh in
            let refreshed = authorizations.withLock { values in
                values.append(forceRefresh)
                return values.contains(true)
            }
            var request = URLRequest(url: URL(string: "https://zoom.us/media")!)
            request.setValue(refreshed ? "Bearer refreshed" : "Bearer expired", forHTTPHeaderField: "Authorization")
            return request
        }
        let loader = RecordingMediaLoader(transport: transport)
        defer { loader.invalidate() }
        let item = loader.makePlayerItem()
        let generator = AVAssetImageGenerator(asset: item.asset)
        let frame = try await generator.image(at: .zero)
        #expect(frame.image.width == 32)
        #expect(frame.image.height == 32)
        #expect(authorizations.withLock { $0.filter { $0 }.count } == 1)
        #expect(!ranges.withLock { $0 }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsAnInFlightRange() async throws {
        RecordingMediaURLProtocol.stopped.withLock { $0 = 0 }
        RecordingMediaURLProtocol.holdBody.withLock { $0 = true }
        let started = Mutex(false)
        RecordingMediaURLProtocol.handler.withLock { value in
            value = { _ in
                started.withLock { $0 = true }
                return (response(status: 206, headers: ["Content-Range": "bytes 0-1/1000", "Content-Length": "2"]), Data())
            }
        }
        defer {
            RecordingMediaURLProtocol.handler.withLock { $0 = nil }
            RecordingMediaURLProtocol.holdBody.withLock { $0 = false }
        }
        let transport = transport()
        defer { transport.invalidate() }
        let operation = Task { try await transport.range(offset: 0, count: 2) }
        for _ in 0..<100 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        for _ in 0..<100 {
            if RecordingMediaURLProtocol.stopped.withLock({ $0 > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started.withLock { $0 })
        #expect(RecordingMediaURLProtocol.stopped.withLock { $0 } > 0)
    }

    private func transport() -> RecordingMediaTransport {
        let configuration = RecordingMediaHTTP.sessionConfiguration()
        configuration.protocolClasses = [RecordingMediaURLProtocol.self]
        return RecordingMediaTransport(configuration: configuration) { _ in
            var request = URLRequest(url: URL(string: "https://zoom.us/media")!)
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            return request
        }
    }
}

private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://zoom.us/media")!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "video/mp4"].merging(headers) { _, value in value })!
}

private final class RecordingMediaURLProtocol: URLProtocol, @unchecked Sendable {
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

// Two frames of 32×32 black video, generated locally with ffmpeg; no external media.
private let recordingMP4Fixture = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMxbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAlx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAAAAABAAAAAAHUbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABf21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAT9zdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAACAAIABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UlsBEAAAAMAQAAAAwCDxIllgAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAAmAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAQAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAABkAAAANAAAAFHN0Y28AAAAAAAAAAQAAA2EAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAAubWRhdAAAABVliIQAFv/+99M/zLLsmiS144e/t/8AAAAJQZohbEFf/tbg"
