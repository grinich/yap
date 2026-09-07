import Foundation

public struct GoogleCalendar: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isPrimary: Bool
    public let colorHex: String?

    public init(id: String, name: String, isPrimary: Bool = false, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
        self.colorHex = colorHex
    }
}

public struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let calendarID: String
    public let calendarName: String
    public let meetingURLs: [URL]
    public let isCancelled: Bool
    public let isAllDay: Bool
    public let recurringEventID: String?

    /// Ambiguous invitations require a choice instead of silently selecting a meeting.
    public var meetingURL: URL? { meetingURLs.count == 1 ? meetingURLs.first : nil }

    public init(id: String, title: String, startDate: Date, endDate: Date,
                calendarID: String, calendarName: String, meetingURLs: [URL] = [],
                isCancelled: Bool = false, isAllDay: Bool = false, recurringEventID: String? = nil) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.meetingURLs = meetingURLs
        self.isCancelled = isCancelled
        self.isAllDay = isAllDay
        self.recurringEventID = recurringEventID
    }
}

public struct CalendarSnapshot: Codable, Sendable {
    public let events: [CalendarEvent]
    public let fetchedAt: Date
    public let calendarIDs: [String]
    public let windowStart: Date
    public let windowEnd: Date

    public init(events: [CalendarEvent], fetchedAt: Date, calendarIDs: [String], windowStart: Date, windowEnd: Date) {
        self.events = events
        self.fetchedAt = fetchedAt
        self.calendarIDs = calendarIDs
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public enum GoogleCalendarError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case notConnected
    case signInExpired
    case authorizationDenied
    case invalidCallback
    case authorizationTimedOut
    case invalidResponse
    case invalidDateWindow
    case httpStatus(Int)
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Add a Google desktop OAuth client in Settings to connect your calendar."
        case .notConnected: "Connect your Google Calendar to see upcoming meetings."
        case .signInExpired: "Your Google connection expired. Connect your calendar again."
        case .authorizationDenied: "Google Calendar access wasn’t granted."
        case .invalidCallback: "Google sign-in couldn’t be verified. Please try again."
        case .authorizationTimedOut: "Google sign-in timed out. Please try again."
        case .invalidResponse: "Google Calendar returned an unexpected response. Try refreshing."
        case .invalidDateWindow: "The calendar date range is invalid."
        case .httpStatus(let code): "Google Calendar couldn’t complete the request (\(code))."
        case .keychain: "Zooom couldn’t securely access your Google connection in Keychain."
        }
    }
}

/// Only explicit Zoom meeting URLs are joinable. No link shorteners or redirects are followed.
public enum ZoomMeetingLinkParser {
    public static func validatedURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com"),
              !host.hasSuffix("."),
              components.percentEncodedPath == components.path else { return nil }
        let pieces = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].isEmpty,
              pieces[1] == "j" || pieces[1] == "s",
              (9...11).contains(pieces[2].count),
              pieces[2].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return components.url
    }

    public static func links(in text: String) -> [URL] {
        // Calendar descriptions often contain anchor HTML. Decode only safe entities needed for URLs.
        let source = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
        guard let expression = try? NSRegularExpression(pattern: #"https://[^\s<>\"']+"#, options: .caseInsensitive) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var seen = Set<String>()
        return expression.matches(in: source, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: source) else { return nil }
            let candidate = String(source[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!)]}"))
            guard let url = validatedURL(candidate), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    public static func meetingLinks(conferenceURLs: [String], location: String?, description: String?) -> [URL] {
        let structured = unique(conferenceURLs.compactMap(validatedURL))
        if !structured.isEmpty { return structured }
        let locationLinks = links(in: location ?? "")
        if !locationLinks.isEmpty { return locationLinks }
        return links(in: description ?? "")
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}
