import Foundation
import WhooshMeetings

enum RecordingChatError: Error, LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case rateLimited
    case rejected(Int)
    case tooLarge
    case invalidResponse
    case unsupportedContent
    case invalidEncoding
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Reconnect Zoom to load this recording’s chat."
        case .forbidden: "Zoom denied access to this recording’s chat. Check your recording permissions."
        case .rateLimited: "Zoom is receiving too many requests. Try loading the chat again in a moment."
        case .rejected(let status): "Zoom could not load this recording’s chat (HTTP \(status))."
        case .tooLarge: "This recording’s chat is larger than the 8 MB viewing limit."
        case .invalidResponse: "Zoom returned an invalid response for this recording’s chat."
        case .unsupportedContent: "Zoom did not return a chat text file. Refresh the recording and try again."
        case .invalidEncoding: "This recording’s chat uses an unsupported text encoding."
        case .incompleteDownload: "The chat download was incomplete. Try loading it again."
        }
    }
}

/// Fetches an authorized chat artifact without persisting either its text or OAuth credentials.
/// Parsing and presentation happen separately so the original message text remains intact.
enum RecordingChatLoader {
    static let maximumByteCount = 8 * 1_024 * 1_024

    @concurrent
    static func load(client: ZoomAccountClient, file: ZoomRecordingFile) async throws -> String {
        guard file.fileSize <= maximumByteCount else { throw RecordingChatError.tooLarge }
        return try await load { forceRefresh in
            try await client.recordingMediaRequest(for: file, forceRefresh: forceRefresh)
        }
    }

    /// The smaller limit and configuration support deterministic network fixtures.
    @concurrent
    static func load(configuration: URLSessionConfiguration = RecordingMediaHTTP.sessionConfiguration(),
                     byteLimit: Int = maximumByteCount,
                     requestProvider: @escaping @Sendable (Bool) async throws -> URLRequest) async throws -> String {
        guard byteLimit > 0, byteLimit <= maximumByteCount else { throw RecordingChatError.invalidResponse }
        let session = URLSession(configuration: configuration, delegate: RecordingMediaRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = try await requestProvider(attempt == 1)
            try Task.checkCancellation()
            request.setValue("text/plain, application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(nil, forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw RecordingChatError.invalidResponse }
            if response.statusCode == 401 && attempt == 0 { continue }
            try checkResponse(response, byteLimit: byteLimit)
            let data: Data = try await withTaskCancellationHandler {
                var data = Data()
                let declaredLength = response.expectedContentLength
                if declaredLength > 0 { data.reserveCapacity(Int(declaredLength)) }
                for try await byte in bytes {
                    guard data.count < byteLimit else { throw RecordingChatError.tooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard declaredLength < 0 || data.count == declaredLength else { throw RecordingChatError.incompleteDownload }
                return data
            } onCancel: { bytes.task.cancel() }
            return try decode(data, charset: response.textEncodingName)
        }
        throw RecordingChatError.unauthorized
    }

    static func checkResponse(_ response: HTTPURLResponse, byteLimit: Int = maximumByteCount) throws {
        switch response.statusCode {
        case 200..<300: break
        case 401: throw RecordingChatError.unauthorized
        case 403: throw RecordingChatError.forbidden
        case 429: throw RecordingChatError.rateLimited
        default: throw RecordingChatError.rejected(response.statusCode)
        }
        // A chat file is fetched whole. An unsolicited partial response would omit messages.
        guard response.statusCode != 206, response.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw RecordingChatError.invalidResponse
        }
        guard response.expectedContentLength <= byteLimit else { throw RecordingChatError.tooLarge }
        guard let mime = response.mimeType?.lowercased(),
              ["text/plain", "application/octet-stream", "binary/octet-stream"].contains(mime) else {
            throw RecordingChatError.unsupportedContent
        }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw RecordingChatError.invalidResponse
        }
    }

    static func decode(_ data: Data, charset: String? = nil) throws -> String {
        let text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            let encoding: String.Encoding = switch charset?.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "utf-16le": .utf16LittleEndian
            case "utf-16", "utf-16be": .utf16BigEndian
            default: .utf8
            }
            text = String(data: data, encoding: encoding)
        }
        guard let text else { throw RecordingChatError.invalidEncoding }
        let prefix = String(text.prefix(1_024)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !["<!doctype html", "<html", "<head", "<body", "<script", "<?xml", "<error"].contains(where: prefix.hasPrefix),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RecordingChatError.unsupportedContent
        }
        return text
    }
}
