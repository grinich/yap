import Foundation
import Darwin

public actor GoogleCalendarClient {
    public nonisolated let configuration: GoogleOAuthConfiguration?
    private let tokenStore: any GoogleTokenStore
    private let transport: CalendarHTTPTransport
    private let cacheURL: URL?
    private var tokens: GoogleOAuthTokens?
    private var loadedTokens = false
    private var generation = UUID()
    private var refreshTask: Task<GoogleOAuthTokens, Error>?
    private var authorizationTask: Task<GoogleDesktopOAuth.Authorization, Error>?
    private var connectionAttemptID: UUID?
    private var tokenMutation: Task<Void, Error>?
    private var cacheRevision = UUID()

    public init(configuration: GoogleOAuthConfiguration?,
                tokenStore: any GoogleTokenStore = KeychainGoogleTokenStore(),
                transport: CalendarHTTPTransport = .live, cacheURL: URL? = nil) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.transport = transport
        self.cacheURL = cacheURL
    }

    public nonisolated var isConfigured: Bool { configuration?.isValid == true }

    public func hasCredentials() async throws -> Bool {
        guard isConfigured else { return false }
        try await loadTokens()
        return tokens != nil
    }

    public func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> [GoogleCalendar] {
        guard let configuration, configuration.isValid else { throw GoogleCalendarError.notConfigured }
        guard connectionAttemptID == nil else { throw GoogleCalendarError.invalidCallback }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        defer {
            if connectionAttemptID == attemptID { connectionAttemptID = nil; authorizationTask = nil }
        }
        let connectionGeneration = generation
        let authorization = Task { try await GoogleDesktopOAuth.authorize(configuration: configuration, openURL: openURL) }
        authorizationTask = authorization
        let result = try await withTaskCancellationHandler {
            try await authorization.value
        } onCancel: { authorization.cancel() }
        try ensureGeneration(connectionGeneration)
        var fields = ["client_id": configuration.clientID, "grant_type": "authorization_code",
                      "code": result.code, "code_verifier": result.verifier, "redirect_uri": result.redirectURI]
        if let secret = configuration.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        let replacement = try await exchange(fields: fields, previousTokens: nil)
        try ensureGeneration(connectionGeneration)
        // Invalidate old requests before queuing the new credential write. Any old write
        // already in progress precedes this one in the persistence queue.
        generation = UUID()
        let commitGeneration = generation
        cacheRevision = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        loadedTokens = true
        try removeCache()
        try await saveTokens(replacement)
        try ensureGeneration(commitGeneration)
        tokens = replacement
        return try await calendars()
    }

    public func disconnect() async throws {
        generation = UUID()
        cacheRevision = UUID()
        authorizationTask?.cancel()
        authorizationTask = nil
        connectionAttemptID = nil
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        loadedTokens = true
        // Independently clear both stores: a Keychain failure must not retain a private agenda.
        var cacheError: (any Error)?
        do { try removeCache() } catch { cacheError = error }
        try await deleteTokens()
        if let cacheError { throw cacheError }
    }

    public func calendars() async throws -> [GoogleCalendar] {
        let operationGeneration = generation
        var pageToken: String?
        var seenTokens = Set<String>()
        var result: [GoogleCalendar] = []
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "250"),
                         URLQueryItem(name: "showHidden", value: "true"),
                         URLQueryItem(name: "minAccessRole", value: "reader")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data: Data
            do { data = try await get(path: "/calendar/v3/users/me/calendarList", query: query) }
            catch GoogleCalendarError.httpStatus(let status) where status == 403 || status == 404 {
                try ensureGeneration(operationGeneration)
                cacheRevision = UUID()
                try removeCache()
                throw GoogleCalendarError.httpStatus(status)
            }
            try ensureGeneration(operationGeneration)
            let page = try JSONDecoder().decode(CalendarListPage.self, from: data)
            result += (page.items ?? []).filter { $0.deleted != true && $0.accessRole != "freeBusyReader" && $0.accessRole != "none" }.map {
                GoogleCalendar(id: $0.id, name: $0.summaryOverride ?? $0.summary ?? "Calendar",
                               isPrimary: $0.primary ?? false, colorHex: $0.backgroundColor)
            }
            pageToken = page.nextPageToken
            if let pageToken, !seenTokens.insert(pageToken).inserted { throw GoogleCalendarError.invalidResponse }
        } while pageToken != nil
        try ensureGeneration(operationGeneration)
        if try pruneCache(keeping: Set(result.map(\.id))) { cacheRevision = UUID() }
        return result.sorted { lhs, rhs in
            lhs.isPrimary != rhs.isPrimary ? lhs.isPrimary : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Each refresh fully replaces a bounded window; no incompatible incremental sync token is used.
    public func events(in calendars: [GoogleCalendar], from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else { throw GoogleCalendarError.invalidDateWindow }
        let operationGeneration = generation
        _ = try await accessToken()
        try ensureGeneration(operationGeneration)
        cacheRevision = UUID()
        let operationCacheRevision = cacheRevision
        try pruneCache(keeping: Set(calendars.map(\.id)))
        var eventsByID: [String: CalendarEvent] = [:]
        for calendar in calendars {
            var pageToken: String?
            var seenTokens = Set<String>()
            repeat {
                var query = [URLQueryItem(name: "timeMin", value: start.ISO8601Format()),
                             URLQueryItem(name: "timeMax", value: end.ISO8601Format()),
                             URLQueryItem(name: "singleEvents", value: "true"),
                             URLQueryItem(name: "showDeleted", value: "false"),
                             URLQueryItem(name: "orderBy", value: "startTime"),
                             URLQueryItem(name: "maxResults", value: "2500")]
                if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let escapedID = calendar.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                let data: Data
                do {
                    data = try await get(path: "/calendar/v3/calendars/\(escapedID)/events", query: query)
                } catch GoogleCalendarError.httpStatus(let status) where status == 403 || status == 404 {
                    try ensureGeneration(operationGeneration)
                    try pruneCache(removing: calendar.id)
                    throw GoogleCalendarError.httpStatus(status)
                }
                let page = try JSONDecoder().decode(GoogleEventPage.self, from: data)
                for event in try page.parsedEvents(calendar: calendar) where !event.isCancelled {
                    eventsByID[event.id] = event
                }
                pageToken = page.nextPageToken
                if let pageToken, !seenTokens.insert(pageToken).inserted { throw GoogleCalendarError.invalidResponse }
            } while pageToken != nil
        }
        try ensureGeneration(operationGeneration)
        let result = eventsByID.values.sorted { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }
        if cacheURL != nil, cacheRevision == operationCacheRevision {
            let snapshot = CalendarSnapshot(events: result, fetchedAt: .now, calendarIDs: calendars.map(\.id), windowStart: start, windowEnd: end)
            try writeCache(snapshot)
        }
        return result
    }

    public func cachedSnapshot() async throws -> CalendarSnapshot? {
        guard isConfigured else { return nil }
        try await loadTokens()
        return try readBoundCache()
    }

    public func clearCachedEvents() throws { cacheRevision = UUID(); try removeCache() }

    private func readBoundCache() throws -> CalendarSnapshot? {
        guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        guard let tokens, let configuration else { try removeCache(); return nil }
        let data = try Data(contentsOf: cacheURL)
        guard let envelope = try? JSONDecoder().decode(CalendarCacheEnvelope.self, from: data),
              envelope.clientID == configuration.clientID, envelope.connectionID == tokens.connectionID else {
            try removeCache()
            return nil
        }
        return envelope.snapshot
    }

    private func writeCache(_ snapshot: CalendarSnapshot) throws {
        guard let cacheURL, let tokens, let configuration else { return }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let envelope = CalendarCacheEnvelope(clientID: configuration.clientID, connectionID: tokens.connectionID, snapshot: snapshot)
        let data = try JSONEncoder().encode(envelope)
        // Create with private permissions before writing any invitation data, then rename atomically.
        let temporary = cacheURL.deletingLastPathComponent().appendingPathComponent(".agenda-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard rename(temporary.path, cacheURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    @discardableResult
    private func pruneCache(keeping ids: Set<String>? = nil, removing removedID: String? = nil) throws -> Bool {
        guard let snapshot = try readBoundCache() else { return false }
        let retainedIDs = snapshot.calendarIDs.filter { (ids?.contains($0) ?? true) && $0 != removedID }
        guard retainedIDs != snapshot.calendarIDs else { return false }
        let retained = Set(retainedIDs)
        try writeCache(CalendarSnapshot(events: snapshot.events.filter { retained.contains($0.calendarID) }, fetchedAt: snapshot.fetchedAt,
                                        calendarIDs: retainedIDs, windowStart: snapshot.windowStart, windowEnd: snapshot.windowEnd))
        return true
    }

    private func removeCache() throws {
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }
    }

    private func ensureGeneration(_ original: UUID) throws {
        guard generation == original else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func loadTokens() async throws {
        if !loadedTokens {
            let original = generation
            let loaded = try await tokenStore.load()
            try ensureGeneration(original)
            if let clientID = loaded?.clientID, clientID != configuration?.clientID {
                loadedTokens = true
                tokens = nil
                try removeCache()
                throw GoogleCalendarError.signInExpired
            }
            tokens = loaded
            loadedTokens = true
        }
    }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let configuration, configuration.isValid else { throw GoogleCalendarError.notConfigured }
        try await loadTokens()
        guard let tokens else { throw GoogleCalendarError.notConnected }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshTask {
            let original = generation
            let refreshed = try await refreshTask.value
            try ensureGeneration(original)
            return refreshed.accessToken
        }
        guard let refreshToken = tokens.refreshToken else { throw GoogleCalendarError.signInExpired }
        let operationGeneration = generation
        let task = Task {
            var fields = ["client_id": configuration.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
            if let secret = configuration.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
            do {
                let replacement = try await self.exchange(fields: fields, previousTokens: tokens)
                try self.ensureGeneration(operationGeneration)
                try await self.saveTokens(replacement)
                try self.ensureGeneration(operationGeneration)
                self.tokens = replacement
                return replacement
            } catch GoogleCalendarError.signInExpired {
                try self.ensureGeneration(operationGeneration)
                self.tokens = nil
                self.generation = UUID()
                self.refreshTask = nil
                self.cacheRevision = UUID()
                try? self.removeCache()
                try await self.deleteTokens()
                throw GoogleCalendarError.signInExpired
            }
        }
        refreshTask = task
        defer { if generation == operationGeneration { refreshTask = nil } }
        let replacement = try await task.value
        try ensureGeneration(operationGeneration)
        return replacement.accessToken
    }

    private func saveTokens(_ value: GoogleOAuthTokens) async throws {
        let previous = tokenMutation
        let store = tokenStore
        let operation = Task { _ = await previous?.result; try await store.save(value) }
        tokenMutation = operation
        try await operation.value
    }

    private func deleteTokens() async throws {
        let previous = tokenMutation
        let store = tokenStore
        let operation = Task { _ = await previous?.result; try await store.delete() }
        tokenMutation = operation
        try await operation.value
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        let operationGeneration = generation
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = path
        components.queryItems = query
        guard let url = components.url else { throw GoogleCalendarError.invalidResponse }
        for attempt in 0...1 {
            let access = try await accessToken(forceRefresh: attempt == 1)
            try ensureGeneration(operationGeneration)
            var request = URLRequest(url: url)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            try ensureGeneration(operationGeneration)
            if response.statusCode == 401, attempt == 0 { continue }
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 401 {
                    generation = UUID()
                    cacheRevision = UUID()
                    tokens = nil
                    loadedTokens = true
                    refreshTask?.cancel()
                    refreshTask = nil
                    try? removeCache()
                    try? await deleteTokens()
                    throw GoogleCalendarError.signInExpired
                }
                throw GoogleCalendarError.httpStatus(response.statusCode)
            }
            return data
        }
        throw GoogleCalendarError.signInExpired
    }

    private func exchange(fields: [String: String], previousTokens: GoogleOAuthTokens?) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(TokenError.self, from: data), error.error == "invalid_grant" {
                throw GoogleCalendarError.signInExpired
            }
            throw GoogleCalendarError.httpStatus(response.statusCode)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !decoded.access_token.isEmpty, decoded.expires_in > 0,
              decoded.token_type.lowercased() == "bearer" else { throw GoogleCalendarError.invalidResponse }
        if let scope = decoded.scope {
            let granted = Set(scope.split(separator: " ").map(String.init))
            guard Set(GoogleOAuthConfiguration.scopes).isSubset(of: granted) else { throw GoogleCalendarError.authorizationDenied }
        }
        return GoogleOAuthTokens(accessToken: decoded.access_token, refreshToken: decoded.refresh_token ?? previousTokens?.refreshToken,
                                 expiresAt: .now.addingTimeInterval(decoded.expires_in), connectionID: previousTokens?.connectionID ?? UUID(),
                                 clientID: configuration?.clientID)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

private struct CalendarCacheEnvelope: Codable {
    let clientID: String
    let connectionID: UUID
    let snapshot: CalendarSnapshot
}

private struct TokenError: Decodable { let error: String }
private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let token_type: String
    let scope: String?
}
private struct CalendarListPage: Decodable {
    let items: [Item]?
    let nextPageToken: String?
    struct Item: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let primary: Bool?
        let backgroundColor: String?
        let deleted: Bool?
        let accessRole: String?
    }
}

struct GoogleEventPage: Decodable {
    let items: [GoogleEventResource]?
    let nextPageToken: String?
    let timeZone: String?

    func parsedEvents(calendar: GoogleCalendar) throws -> [CalendarEvent] {
        try (items ?? []).compactMap { try $0.event(calendar: calendar, fallbackTimeZone: timeZone) }
    }
}

struct GoogleEventResource: Decodable {
    let id: String
    let summary: String?
    let status: String?
    let start: EventDate?
    let end: EventDate?
    let location: String?
    let description: String?
    let conferenceData: Conference?
    let recurringEventId: String?
    let originalStartTime: EventDate?

    struct EventDate: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?

        func parsed(fallbackTimeZone: String?) -> Date? {
            if let dateTime {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let result = formatter.date(from: dateTime) { return result }
                formatter.formatOptions = [.withInternetDateTime]
                if let result = formatter.date(from: dateTime) { return result }
                // Google also permits an offset-free timestamp when its IANA zone is explicit.
                if let timeZone, let zone = TimeZone(identifier: timeZone) {
                    let localFormatter = DateFormatter()
                    localFormatter.locale = Locale(identifier: "en_US_POSIX")
                    localFormatter.calendar = Calendar(identifier: .gregorian)
                    localFormatter.timeZone = zone
                    localFormatter.isLenient = false
                    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                        localFormatter.dateFormat = format
                        if let result = localFormatter.date(from: dateTime) { return result }
                    }
                }
                return nil
            }
            if let date {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(identifier: timeZone ?? fallbackTimeZone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                return formatter.date(from: date)
            }
            return nil
        }
    }

    struct Conference: Decodable {
        let entryPoints: [EntryPoint]?
        struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
    }

    func event(calendar: GoogleCalendar, fallbackTimeZone: String?) throws -> CalendarEvent? {
        // Cancelled tombstones may contain only an ID. Full-window replacement removes them.
        guard status != "cancelled" else { return nil }
        guard let startDate = start?.parsed(fallbackTimeZone: fallbackTimeZone),
              let endDate = end?.parsed(fallbackTimeZone: fallbackTimeZone), endDate >= startDate else {
            throw GoogleCalendarError.invalidResponse
        }
        let structuredURLs = conferenceData?.entryPoints?.filter { $0.entryPointType == "video" }.compactMap(\.uri) ?? []
        return CalendarEvent(id: "\(calendar.id):\(id)", title: summary?.isEmpty == false ? summary! : "Untitled meeting",
                             startDate: startDate, endDate: endDate, calendarID: calendar.id, calendarName: calendar.name,
                             meetingURLs: ZoomMeetingLinkParser.meetingLinks(conferenceURLs: structuredURLs, location: location, description: description),
                             isAllDay: start?.date != nil, recurringEventID: recurringEventId)
    }
}
