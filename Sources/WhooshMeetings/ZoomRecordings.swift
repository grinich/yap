import CryptoKit
import Foundation

/// A single recorded meeting occurrence. Zoom's UUID distinguishes recurring meetings.
public struct ZoomRecordingMeeting: Identifiable, Sendable, Equatable, Decodable {
    public let id: String
    public let topic: String
    public let startTime: Date
    /// Meeting duration, in minutes.
    public let duration: Int
    public let files: [ZoomRecordingFile]
    /// Zoom's browser link for this meeting's recordings, when available.
    public let shareURL: URL?

    public init(id: String, topic: String, startTime: Date, duration: Int, files: [ZoomRecordingFile], shareURL: URL? = nil) {
        self.id = id
        self.topic = topic
        self.startTime = startTime
        self.duration = duration
        self.files = files
        self.shareURL = shareURL.flatMap(ZoomRecordingShareURL.validated)
    }

    public var playableVideoFiles: [ZoomRecordingFile] { files.filter(\.isPlayableVideo) }
    public var chatFiles: [ZoomRecordingFile] { files.filter(\.isChatTranscript) }

    /// Prefer the meeting's share page; an individual video page is a fallback.
    /// Download URLs and API authorization tokens are never copied for sharing.
    public var shareableURL: URL? {
        if let shareURL { return shareURL }
        return files.lazy
            .filter { $0.status.lowercased() == "completed" && $0.fileType.uppercased() == "MP4" }
            .compactMap { $0.playURL.flatMap(ZoomRecordingShareURL.validated) }
            .first
    }

    private enum CodingKeys: String, CodingKey {
        case id = "uuid", topic, startTime = "start_time", duration, files = "recording_files"
        case shareURL = "share_url"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "Missing recording UUID")
        }
        topic = try values.decodeIfPresent(String.self, forKey: .topic) ?? "Zoom recording"
        duration = try values.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        files = try values.decodeIfPresent([ZoomRecordingFile].self, forKey: .files) ?? []
        shareURL = try values.decodeIfPresent(String.self, forKey: .shareURL)
            .flatMap(URL.init(string:)).flatMap(ZoomRecordingShareURL.validated)
        let rawDate = try values.decode(String.self, forKey: .startTime)
        guard let date = ZoomRecordingDate.parse(rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .startTime, in: values, debugDescription: "Invalid recording date")
        }
        startTime = date
    }
}

public struct ZoomRecordingFile: Identifiable, Sendable, Equatable, Decodable {
    public let id: String
    public let recordingType: String
    public let fileType: String
    public let fileSize: Int64
    public let downloadURL: URL?
    public let playURL: URL?
    public let status: String
    public let recordingStart: Date?
    public let recordingEnd: Date?

    public init(id: String, recordingType: String, fileType: String, fileSize: Int64,
                downloadURL: URL?, playURL: URL?, status: String,
                recordingStart: Date? = nil, recordingEnd: Date? = nil) {
        self.id = id
        self.recordingType = recordingType
        self.fileType = fileType
        self.fileSize = fileSize
        self.downloadURL = downloadURL
        self.playURL = playURL
        self.status = status
        self.recordingStart = recordingStart
        self.recordingEnd = recordingEnd
    }

    /// Zoom's play_url points to a webpage; native media uses the download URL.
    public var mediaURL: URL? {
        guard let downloadURL, Self.isTrustedMediaURL(downloadURL) else { return nil }
        return downloadURL
    }

    public var isPlayableVideo: Bool {
        status.lowercased() == "completed" && fileType.uppercased() == "MP4" && mediaURL != nil
    }

    public var isChatTranscript: Bool {
        status.lowercased() == "completed"
            && (fileType.uppercased() == "CHAT" || recordingType.lowercased() == "chat_file")
            && mediaURL != nil
    }

    public var displayName: String {
        switch recordingType {
        case "shared_screen_with_speaker_view": "Screen and speaker"
        case "shared_screen_with_gallery_view": "Screen and gallery"
        case "shared_screen_with_speaker_view(CC)": "Screen and speaker with captions"
        case "active_speaker": "Active speaker"
        case "gallery_view": "Gallery view"
        case "shared_screen": "Shared screen"
        case "speaker_view": "Speaker view"
        case "chat_file": "Chat"
        default: recordingType.isEmpty ? "Video" : recordingType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Only attach OAuth authorization to HTTPS URLs owned by Zoom. CDN redirects
    /// must be independently validated by the media transport and drop authorization.
    public static func isTrustedMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              let host = url.host?.lowercased() else { return false }
        return ["zoom.us", "zoom.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingType = "recording_type", fileType = "file_type", fileSize = "file_size"
        case downloadURL = "download_url", playURL = "play_url", status
        case recordingStart = "recording_start", recordingEnd = "recording_end"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordingType = try values.decodeIfPresent(String.self, forKey: .recordingType) ?? ""
        fileType = try values.decodeIfPresent(String.self, forKey: .fileType) ?? ""
        fileSize = try values.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
        downloadURL = try values.decodeIfPresent(String.self, forKey: .downloadURL).flatMap(URL.init(string:))
        playURL = try values.decodeIfPresent(String.self, forKey: .playURL).flatMap(URL.init(string:))
        let start = try values.decodeIfPresent(String.self, forKey: .recordingStart)
        let end = try values.decodeIfPresent(String.self, forKey: .recordingEnd)
        recordingStart = start.flatMap(ZoomRecordingDate.parse)
        recordingEnd = end.flatMap(ZoomRecordingDate.parse)
        if let providerID = try values.decodeIfPresent(String.self, forKey: .id) {
            guard !providerID.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "Empty recording file ID")
            }
            id = providerID
        } else {
            // Zoom explicitly omits IDs on CC/TIMELINE attachments. Keep these
            // non-playable files without rejecting the meeting's valid videos.
            guard ["CC", "TIMELINE"].contains(fileType.uppercased()) else {
                throw DecodingError.keyNotFound(CodingKeys.id,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing recording file ID"))
            }
            let identity = try JSONEncoder().encode([fileType.uppercased(), downloadURL?.absoluteString ?? "", start ?? "", end ?? ""])
            id = "attachment-" + Data(SHA256.hash(data: identity)).zoomBase64URL
        }
    }
}

private enum ZoomRecordingShareURL {
    static func validated(_ url: URL) -> URL? {
        guard ZoomRecordingFile.isTrustedMediaURL(url),
              url.path.hasPrefix("/rec/share/") || url.path.hasPrefix("/rec/play/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let credentialNames: Set<String> = [
            "access_token", "download_access_token", "download_token", "authorization", "token", "tk", "jwt", "zak"
        ]
        guard !(components.queryItems ?? []).contains(where: { credentialNames.contains($0.name.lowercased()) }) else {
            return nil
        }
        return url
    }
}

private enum ZoomRecordingDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public struct ZoomRecordingPage: Sendable, Equatable, Decodable {
    public let meetings: [ZoomRecordingMeeting]
    public let nextPageToken: String

    public init(meetings: [ZoomRecordingMeeting], nextPageToken: String = "") {
        self.meetings = meetings
        self.nextPageToken = nextPageToken
    }

    private enum CodingKeys: String, CodingKey { case meetings, nextPageToken = "next_page_token" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetings = try values.decode([ZoomRecordingMeeting].self, forKey: .meetings)
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken) ?? ""
    }
}
