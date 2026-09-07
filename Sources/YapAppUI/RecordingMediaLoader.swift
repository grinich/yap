import AVFoundation
import Foundation
import Synchronization
import UniformTypeIdentifiers
import YapMeetings

/// Keeps OAuth headers out of the asset URL and serves AVFoundation only the byte ranges it requests.
/// Retain this object for the life of its player item, and invalidate it when leaving the recording.
@MainActor
final class RecordingMediaLoader: NSObject, AVAssetResourceLoaderDelegate {
    var onFailure: (@MainActor (Error) -> Void)?

    private let transport: RecordingMediaTransport
    private let asset: AVURLAsset
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var contentLength: Int64?
    private var isInvalidated = false
    private var reportedFailure = false

    convenience init(client: ZoomAccountClient, file: ZoomRecordingFile) {
        self.init(transport: RecordingMediaTransport { forceRefresh in
            try await client.recordingMediaRequest(for: file, forceRefresh: forceRefresh)
        })
    }

    init(transport: RecordingMediaTransport) {
        self.transport = transport
        // This opaque URL is deliberately unrelated to Zoom's authenticated download URL.
        asset = AVURLAsset(url: URL(string: "yap-recording://media/\(UUID().uuidString).mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    func makePlayerItem() -> AVPlayerItem { AVPlayerItem(asset: asset) }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        asset.resourceLoader.setDelegate(nil, queue: nil)
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        transport.invalidate()
        asset.cancelLoading()
        onFailure = nil
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                     shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated {
            guard !isInvalidated else { return false }
            let identifier = ObjectIdentifier(loadingRequest)
            pending[identifier] = Task { [weak self] in
                guard let self else { return }
                defer { pending.removeValue(forKey: identifier) }
                do {
                    try await serve(loadingRequest)
                    if !loadingRequest.isCancelled && !isInvalidated { loadingRequest.finishLoading() }
                } catch {
                    guard !loadingRequest.isCancelled && !isInvalidated && !Task.isCancelled else { return }
                    loadingRequest.finishLoading(with: error)
                    if !reportedFailure {
                        reportedFailure = true
                        onFailure?(error)
                    }
                }
            }
            return true
        }
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                     didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated {
            pending.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
        }
    }

    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = loadingRequest.dataRequest
        let start = max(dataRequest?.requestedOffset ?? 0, dataRequest?.currentOffset ?? 0)
        guard start >= 0 else { throw RecordingMediaError.invalidResponse }
        let requestedEnd: Int64
        if let dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            let (end, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
            guard !overflow && end >= start else { throw RecordingMediaError.invalidResponse }
            requestedEnd = end
        } else {
            requestedEnd = Int64.max
        }
        var offset = start
        var refreshedAuthorization = false
        if let contentLength, let information = loadingRequest.contentInformationRequest {
            information.contentType = UTType.mpeg4Movie.identifier
            information.contentLength = contentLength
            information.isByteRangeAccessSupported = true
        }
        repeat {
            try Task.checkCancellation()
            guard !isInvalidated && !loadingRequest.isCancelled else { throw CancellationError() }
            if let contentLength, offset >= contentLength { break }
            let remaining = dataRequest == nil ? 2 : requestedEnd - offset
            if remaining <= 0 { break }
            let count = min(Int64(RecordingMediaTransport.maximumChunkSize), remaining)
            let chunk: RecordingMediaChunk
            do {
                chunk = try await transport.range(offset: offset, count: Int(count))
            } catch RecordingMediaError.unauthorized where !refreshedAuthorization {
                // One token refresh for this AVFoundation loading request, including all its chunks.
                refreshedAuthorization = true
                chunk = try await transport.range(offset: offset, count: Int(count), forceRefresh: true)
            }
            try Task.checkCancellation()
            guard !isInvalidated && !loadingRequest.isCancelled else { throw CancellationError() }
            if let contentLength, contentLength != chunk.totalLength { throw RecordingMediaError.invalidResponse }
            contentLength = chunk.totalLength
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = UTType.mpeg4Movie.identifier
                information.contentLength = chunk.totalLength
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest else { return }
            dataRequest.respond(with: chunk.data)
            offset += Int64(chunk.data.count)
        } while offset < min(requestedEnd, contentLength ?? Int64.max)
    }
}

enum RecordingMediaError: Error, LocalizedError, Equatable {
    case streamingUnavailable
    case unauthorized
    case forbidden
    case rateLimited
    case rejected(Int)
    case invalidResponse
    case unsupportedContent
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .streamingUnavailable: "Zoom could not stream this recording. Download it to play locally."
        case .unauthorized: "Zoom authorization expired. Reconnect Zoom and try again."
        case .forbidden: "Zoom denied access to this recording. Check your cloud recording permissions."
        case .rateLimited: "Zoom is receiving too many requests. Try again in a moment."
        case .rejected(let status): "Zoom could not load this recording (HTTP \(status))."
        case .invalidResponse: "Zoom returned an invalid recording response."
        case .unsupportedContent: "Zoom did not return an MP4 video for this recording."
        case .incompleteDownload: "The recording download was incomplete. Try downloading it again."
        }
    }
}

struct RecordingMediaChunk: Sendable {
    let data: Data
    let totalLength: Int64
}

/// A small, account-lifetime memory cache for revisiting headers and recently played ranges.
/// The lock also makes invalidation immediate: a late response cannot restore cleared video data.
final class RecordingMediaRangeCache: Sendable {
    private struct Segment: Sendable {
        let offset: Int64
        let chunk: RecordingMediaChunk
        var lastAccess: UInt64
        var end: Int64 { offset + Int64(chunk.data.count) }
    }

    private struct State: Sendable {
        var segments: [Segment] = []
        var bytes = 0
        var clock: UInt64 = 0
        var invalidated = false
    }

    private let byteLimit: Int
    private let state = Mutex(State())

    init(byteLimit: Int = 8 * 1_024 * 1_024) { self.byteLimit = max(0, byteLimit) }

    var cachedByteCount: Int { state.withLock { $0.bytes } }

    func chunk(offset: Int64, count: Int) -> RecordingMediaChunk? {
        guard offset >= 0, count > 0, count <= RecordingMediaTransport.maximumChunkSize,
              offset <= Int64.max - Int64(count) else { return nil }
        return state.withLock { value in
            guard !value.invalidated, let total = value.segments.first?.chunk.totalLength, offset < total else { return nil }
            let end = min(offset + Int64(count), total)
            var cursor = offset
            var pieces: [(Int, Range<Int>)] = []
            while cursor < end {
                // Prefer the segment with the longest coverage when previously requested ranges overlap.
                guard let index = value.segments.indices.filter({
                    value.segments[$0].offset <= cursor && value.segments[$0].end > cursor
                }).max(by: { value.segments[$0].end < value.segments[$1].end }) else { return nil }
                let segment = value.segments[index]
                let next = min(end, segment.end)
                pieces.append((index, Int(cursor - segment.offset)..<Int(next - segment.offset)))
                cursor = next
            }
            value.clock &+= 1
            for (index, _) in pieces { value.segments[index].lastAccess = value.clock }
            if let (index, range) = pieces.first, pieces.count == 1,
               range.lowerBound == 0, range.upperBound == value.segments[index].chunk.data.count {
                return value.segments[index].chunk
            }
            var data = Data()
            data.reserveCapacity(Int(end - offset))
            for (index, range) in pieces { data.append(value.segments[index].chunk.data[range]) }
            return RecordingMediaChunk(data: data, totalLength: total)
        }
    }

    func store(_ chunk: RecordingMediaChunk, offset: Int64) {
        guard offset >= 0, !chunk.data.isEmpty, chunk.data.count <= byteLimit,
              chunk.data.count <= RecordingMediaTransport.maximumChunkSize,
              chunk.totalLength >= Int64(chunk.data.count),
              offset <= chunk.totalLength - Int64(chunk.data.count) else { return }
        state.withLock { value in
            guard !value.invalidated else { return }
            if let total = value.segments.first?.chunk.totalLength, total != chunk.totalLength {
                value.segments.removeAll()
                value.bytes = 0
            }
            let end = offset + Int64(chunk.data.count)
            value.segments.removeAll { offset <= $0.offset && end >= $0.end }
            value.bytes = value.segments.reduce(0) { $0 + $1.chunk.data.count }
            value.clock &+= 1
            value.segments.append(Segment(offset: offset, chunk: chunk, lastAccess: value.clock))
            value.bytes += chunk.data.count
            while value.bytes > byteLimit,
                  let oldest = value.segments.indices.min(by: { value.segments[$0].lastAccess < value.segments[$1].lastAccess }) {
                value.bytes -= value.segments.remove(at: oldest).chunk.data.count
            }
        }
    }

    func invalidate() {
        state.withLock {
            $0.invalidated = true
            $0.segments.removeAll()
            $0.bytes = 0
        }
    }
}

/// Network work, including collecting the bounded range, stays off the main actor.
final class RecordingMediaTransport: Sendable {
    static let maximumChunkSize = 512 * 1_024
    private let session: URLSession
    private let cache = RecordingMediaRangeCache()
    private let requestProvider: @Sendable (Bool) async throws -> URLRequest

    init(configuration: URLSessionConfiguration = RecordingMediaHTTP.sessionConfiguration(),
         requestProvider: @escaping @Sendable (Bool) async throws -> URLRequest) {
        self.requestProvider = requestProvider
        session = URLSession(configuration: configuration, delegate: RecordingMediaRedirects(), delegateQueue: nil)
    }

    func invalidate() {
        cache.invalidate()
        session.invalidateAndCancel()
    }

    deinit { session.invalidateAndCancel() }

    @concurrent
    func range(offset: Int64, count: Int, forceRefresh: Bool = false) async throws -> RecordingMediaChunk {
        guard offset >= 0, count > 0, count <= Self.maximumChunkSize,
              offset <= Int64.max - Int64(count) else { throw RecordingMediaError.invalidResponse }
        try Task.checkCancellation()
        if let cached = cache.chunk(offset: offset, count: count) { return cached }
        var request = try await requestProvider(forceRefresh)
        try Task.checkCancellation()
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("video/mp4, application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw RecordingMediaError.invalidResponse }
        let range = try RecordingMediaHTTP.validateRange(response, offset: offset, count: count)
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(Int(range.length))
            for try await byte in bytes {
                guard data.count < range.length else { throw RecordingMediaError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard data.count == range.length else { throw RecordingMediaError.incompleteDownload }
            let chunk = RecordingMediaChunk(data: data, totalLength: range.total)
            cache.store(chunk, offset: offset)
            return chunk
        } onCancel: { bytes.task.cancel() }
    }
}

enum RecordingDownloadService {
    /// URLSession writes the response to disk, so saving a long meeting never buffers the full video.
    @concurrent
    static func download(client: ZoomAccountClient, file: ZoomRecordingFile, to destination: URL) async throws {
        let session = URLSession(configuration: RecordingMediaHTTP.sessionConfiguration(),
                                 delegate: RecordingMediaRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = try await client.recordingMediaRequest(for: file, forceRefresh: attempt == 1)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("video/mp4, application/octet-stream", forHTTPHeaderField: "Accept")
            let (temporaryURL, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw RecordingMediaError.invalidResponse }
            if response.statusCode == 401 && attempt == 0 { continue }
            try RecordingMediaHTTP.checkStatus(response)
            guard response.statusCode == 200 else { throw RecordingMediaError.invalidResponse }
            try RecordingMediaHTTP.checkContentType(response)
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0,
                  response.expectedContentLength < 0 || size == response.expectedContentLength,
                  file.fileSize <= 0 || size == file.fileSize else { throw RecordingMediaError.incompleteDownload }
            let handle = try FileHandle(forReadingFrom: temporaryURL)
            let prefix: Data
            do {
                prefix = try handle.read(upToCount: 16) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard RecordingMediaHTTP.isMP4Prefix(prefix) else { throw RecordingMediaError.unsupportedContent }
            try Task.checkCancellation()
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Stage beside the destination so replacement is atomic even across different volumes.
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".yap-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: temporaryURL, to: staging)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            return
        }
        throw RecordingMediaError.unauthorized
    }
}

struct RecordingHTTPRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64
    var length: Int64 { end - start + 1 }
}

enum RecordingMediaHTTP {
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    static func checkStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw RecordingMediaError.unauthorized
        case 403: throw RecordingMediaError.forbidden
        case 429: throw RecordingMediaError.rateLimited
        default: throw RecordingMediaError.rejected(response.statusCode)
        }
    }

    static func checkContentType(_ response: HTTPURLResponse) throws {
        guard let type = response.mimeType?.lowercased(),
              ["video/mp4", "application/mp4", "application/octet-stream", "binary/octet-stream"].contains(type) else {
            throw RecordingMediaError.unsupportedContent
        }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw RecordingMediaError.invalidResponse
        }
    }

    static func validateRange(_ response: HTTPURLResponse, offset: Int64, count: Int) throws -> RecordingHTTPRange {
        try checkStatus(response)
        // A full response cannot satisfy arbitrary seeks. Cancel it before reading the body.
        guard response.statusCode != 200 else { throw RecordingMediaError.streamingUnavailable }
        guard response.statusCode == 206, offset >= 0, count > 0,
              count <= RecordingMediaTransport.maximumChunkSize,
              offset <= Int64.max - Int64(count) else { throw RecordingMediaError.invalidResponse }
        try checkContentType(response)
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.lowercased().hasPrefix("bytes ") else { throw RecordingMediaError.invalidResponse }
        let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw RecordingMediaError.invalidResponse }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              let total = Int64(fields[1]), start == offset, end >= start, total > end,
              end == min(offset + Int64(count) - 1, total - 1) else { throw RecordingMediaError.invalidResponse }
        let range = RecordingHTTPRange(start: start, end: end, total: total)
        guard response.expectedContentLength < 0 || response.expectedContentLength == range.length else {
            throw RecordingMediaError.invalidResponse
        }
        return range
    }

    static func isMP4Prefix(_ data: Data) -> Bool {
        guard data.count >= 8, let box = String(data: data[4..<8], encoding: .ascii) else { return false }
        return ["ftyp", "moov", "mdat", "free", "wide", "skip"].contains(box)
    }

    static func redirect(_ proposed: URLRequest, from source: URLRequest) -> URLRequest? {
        guard let target = proposed.url, target.scheme?.lowercased() == "https",
              target.host != nil, target.user == nil, target.password == nil,
              target.port == nil || target.port == 443 else { return nil }
        var safe = proposed
        // CDN redirects can contain signed download URLs. They must never receive the Zoom OAuth token.
        let mayAuthorize = trustedZoomHost(source.url?.host) && trustedZoomHost(target.host)
        safe.setValue(mayAuthorize ? source.value(forHTTPHeaderField: "Authorization") : nil,
                      forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Referer")
        safe.setValue(source.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return safe
    }

    private static func trustedZoomHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com")
    }
}

final class RecordingMediaRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard var source = task.currentRequest else { completionHandler(nil); return }
        source.url = response.url
        completionHandler(RecordingMediaHTTP.redirect(request, from: source))
    }
}
