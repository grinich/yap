import Foundation
import YapMeetings

enum RecordingTranscriptError: Error, LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case rateLimited
    case rejected(Int)
    case tooLarge
    case invalidResponse
    case unsupportedContent
    case invalidEncoding
    case incompleteDownload

    init(_ error: RecordingChatError) {
        self = switch error {
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .rateLimited: .rateLimited
        case .rejected(let status): .rejected(status)
        case .tooLarge: .tooLarge
        case .invalidResponse: .invalidResponse
        case .unsupportedContent: .unsupportedContent
        case .invalidEncoding: .invalidEncoding
        case .incompleteDownload: .incompleteDownload
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Reconnect Zoom to load this recording’s transcript."
        case .forbidden: "Zoom denied access to this recording’s transcript. Check your recording permissions."
        case .rateLimited: "Zoom is receiving too many requests. Try loading the transcript again in a moment."
        case .rejected(let status): "Zoom could not load this recording’s transcript (HTTP \(status))."
        case .tooLarge: "This recording’s transcript is larger than the 8 MB viewing limit."
        case .invalidResponse: "Zoom returned an invalid response for this recording’s transcript."
        case .unsupportedContent: "Zoom did not return a transcript text file. Refresh the recording and try again."
        case .invalidEncoding: "This recording’s transcript uses an unsupported text encoding."
        case .incompleteDownload: "The transcript download was incomplete. Try loading it again."
        }
    }
}

/// Speech transcripts use the same bounded authenticated text transport as saved chat.
/// WebVTT parsing is separate; this loader never downloads or persists a recording video.
enum RecordingTranscriptLoader {
    static let maximumByteCount = RecordingChatLoader.maximumByteCount

    @concurrent
    static func load(client: ZoomAccountClient, file: ZoomRecordingFile) async throws -> String {
        guard file.isAudioTranscript else { throw RecordingTranscriptError.unsupportedContent }
        guard file.fileSize <= maximumByteCount else { throw RecordingTranscriptError.tooLarge }
        return try await load { forceRefresh in
            try await client.recordingMediaRequest(for: file, forceRefresh: forceRefresh)
        }
    }

    @concurrent
    static func load(configuration: URLSessionConfiguration = RecordingMediaHTTP.sessionConfiguration(),
                     byteLimit: Int = maximumByteCount,
                     requestProvider: @escaping @Sendable (Bool) async throws -> URLRequest) async throws -> String {
        do {
            return try await RecordingChatLoader.load(configuration: configuration, byteLimit: byteLimit,
                mimeTypes: ["text/vtt"] + RecordingChatLoader.chatMIMETypes, requestProvider: requestProvider)
        } catch let error as RecordingChatError {
            throw RecordingTranscriptError(error)
        }
    }
}
