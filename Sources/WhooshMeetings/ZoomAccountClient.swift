import Foundation

/// Zoom identity and SDK signing for the app owner's private, locally configured build.
/// Creates the owner's instant meetings and reads their cloud recordings.
/// No account-wide APIs or invitations are invoked here.
public actor ZoomAccountClient {
    private let store: any ZoomCredentialStore
    private let transport: ZoomHTTPTransport
    private var cachedTokens: ZoomOAuthTokens?
    private var refreshTask: Task<ZoomOAuthTokens, Error>?
    private var connectionTask: Task<Void, Error>?
    private var storeMutationTask: Task<Void, Error>?
    private var generation = UUID()
    private var pendingHostedMeeting: Int64?
    private var meetingCreationTask: Task<Int64, Error>?
    private var meetingCreationTaskID: UUID?
    private var meetingCreationWaiters: Set<UUID> = []
    private var meetingCreationUnconfirmed = false

    public init(store: any ZoomCredentialStore = KeychainZoomCredentialStore(), transport: ZoomHTTPTransport = .live) {
        self.store = store
        self.transport = transport
    }

    public func isConfigured() async throws -> Bool {
        if let storeMutationTask { _ = try? await storeMutationTask.value }
        return try await store.loadConfiguration()?.isValid == true
    }

    /// Indicates saved authorization, not that Zoom has validated this connection during this launch.
    public func hasSavedConnection() async throws -> Bool {
        if let storeMutationTask { _ = try? await storeMutationTask.value }
        guard let configuration = try await store.loadConfiguration(),
              let tokens = try await store.loadTokens() else { return false }
        return tokens.clientID == configuration.oauthPublicClientID
    }

    public func configure(_ configuration: ZoomPersonalConfiguration) async throws {
        guard configuration.isValid else { throw ZoomAccountError.invalidConfiguration }
        cancelPendingOperations()
        try await mutateStore(generation: generation) { store in
            try await store.deleteTokens()
            try await store.saveConfiguration(configuration)
        }
    }

    public func configure(fromJSON data: Data) async throws {
        guard data.count <= 16_384, let decoded = try? JSONDecoder().decode(ZoomPersonalConfiguration.self, from: data) else {
            throw ZoomAccountError.invalidConfiguration
        }
        try await configure(decoded)
    }

    public func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws {
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        // A new authorization may select a different Zoom account. An old refresh
        // must not later overwrite the new identity, even when the public client ID matches.
        cancelPendingOperations()
        let operationGeneration = generation
        let configuration = try await configuration()
        guard operationGeneration == generation else { throw CancellationError() }
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        let task = Task { [weak self] in
            let authorization = try await ZoomDesktopOAuth.authorize(publicClientID: configuration.oauthPublicClientID, openURL: openURL)
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            let tokens = try await self.exchange(fields: ["grant_type": "authorization_code",
                "client_id": configuration.oauthPublicClientID, "code": authorization.code,
                "redirect_uri": authorization.redirectURI, "code_verifier": authorization.verifier],
                clientID: configuration.oauthPublicClientID, previousRefreshToken: nil)
            // The minimal-scope ZAK read verifies that the newly granted connection works.
            _ = try await self.fetchZAK(accessToken: tokens.accessToken)
            try await self.installTokens(tokens, generation: operationGeneration)
        }
        connectionTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if operationGeneration == generation { connectionTask = nil }
        } catch {
            if operationGeneration == generation { connectionTask = nil }
            throw error
        }
    }

    /// Deletes local authorization. Revocation can be performed in Zoom's app management page.
    public func disconnect() async throws {
        cancelPendingOperations()
        try await mutateStore(generation: generation) { try await $0.deleteTokens() }
    }

    public func removeConfiguration() async throws {
        cancelPendingOperations()
        try await mutateStore(generation: generation) { try await $0.deleteAll() }
    }

    public func meetingCredentials() async throws -> ZoomMeetingCredentials {
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        let currentGeneration = generation
        let configuration = try await configuration()
        guard generation == currentGeneration else { throw CancellationError() }
        var token = try await accessToken(configuration: configuration, generation: currentGeneration)
        let zak: FetchedZAK
        do { zak = try await fetchZAK(accessToken: token) }
        catch ZoomAccountError.notConnected {
            token = try await accessToken(configuration: configuration, generation: currentGeneration, forceRefresh: true)
            zak = try await fetchZAK(accessToken: token)
        }
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        return ZoomMeetingCredentials(sdkJWT: try ZoomSDKJWT.make(configuration: configuration), zak: zak.token,
                                      zakExpiresAt: zak.expiresAt)
    }

    /// Prepare one instant meeting, retaining its ID across SDK failures or cancelled attempts.
    /// Only an SDK-confirmed successful start consumes it, so retries do not create extra rooms.
    public func hostingCredentials(title: String) async throws -> ZoomHostingCredentials {
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        let expected = generation
        try requireGeneration(expected)
        let number: Int64
        if let pendingHostedMeeting { number = pendingHostedMeeting }
        else {
            let task: Task<Int64, Error>
            let taskID: UUID
            if let existing = meetingCreationTask, let existingID = meetingCreationTaskID {
                task = existing; taskID = existingID
            }
            else {
                guard !meetingCreationUnconfirmed else { throw ZoomAccountError.meetingCreationUnconfirmed }
                taskID = UUID()
                task = Task { try await self.createInstantMeeting(title: title, generation: expected) }
                meetingCreationTask = task; meetingCreationTaskID = taskID
            }
            let waiterID = UUID()
            meetingCreationWaiters.insert(waiterID)
            defer { meetingCreationWaiters.remove(waiterID) }
            do {
                number = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    Task { await self.cancelCreationWaiter(waiterID, taskID: taskID, generation: expected) }
                }
                if expected == generation && meetingCreationTaskID == taskID {
                    meetingCreationTask = nil; meetingCreationTaskID = nil
                }
            } catch {
                if expected == generation && meetingCreationTaskID == taskID {
                    meetingCreationTask = nil; meetingCreationTaskID = nil
                }
                throw error
            }
        }
        try requireGeneration(expected)
        let credentials = try await meetingCredentials()
        try requireGeneration(expected)
        return ZoomHostingCredentials(meetingNumber: number, credentials: credentials)
    }

    public func markHostedMeetingStarted(_ meetingNumber: Int64) {
        if pendingHostedMeeting == meetingNumber { pendingHostedMeeting = nil }
    }

    /// List the connected owner's cloud recordings in an inclusive UTC date range
    /// of at most one month. Keep subsequent pages on the same range; Zoom page
    /// tokens expire after 15 minutes.
    public func recordings(from: Date, to: Date, nextPageToken: String = "") async throws -> ZoomRecordingPage {
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        let expected = generation
        try requireGeneration(expected)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        guard firstDay <= lastDay, let limit = calendar.date(byAdding: .month, value: 1, to: firstDay),
              lastDay <= limit else { throw ZoomAccountError.invalidRecordingDateRange }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var components = URLComponents(string: "https://api.zoom.us/v2/users/me/recordings")!
        components.queryItems = [URLQueryItem(name: "from", value: formatter.string(from: firstDay)),
                                 URLQueryItem(name: "to", value: formatter.string(from: lastDay)),
                                 URLQueryItem(name: "page_size", value: "100")]
        if !nextPageToken.isEmpty { components.queryItems?.append(URLQueryItem(name: "next_page_token", value: nextPageToken)) }
        // A page token is opaque; form-style query parsers must not turn '+' into a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ZoomAccountError.invalidResponse }
        let configuration = try await configuration()
        try requireGeneration(expected)
        var token = try await accessToken(configuration: configuration, generation: expected)
        for attempt in 0...1 {
            try requireGeneration(expected)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpShouldHandleCookies = false
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch {
                try requireGeneration(expected)
                throw error
            }
            try requireGeneration(expected)
            if (try? JSONDecoder().decode(ProviderErrorResponse.self, from: data).code) == 4711 {
                throw ZoomAccountError.missingRecordingScope
            }
            if response.statusCode == 401 {
                guard attempt == 0 else { throw ZoomAccountError.notConnected }
                token = try await accessToken(configuration: configuration, generation: expected, forceRefresh: true)
                continue
            }
            if response.statusCode == 403 { throw ZoomAccountError.missingRecordingScope }
            try Self.checkStatus(response)
            guard let page = try? JSONDecoder().decode(ZoomRecordingPage.self, from: data) else {
                throw ZoomAccountError.invalidResponse
            }
            return page
        }
        throw ZoomAccountError.notConnected
    }

    /// Returns an in-memory authorized request for a completed video, chat, or audio transcript. Never persist
    /// this request or place its bearer token in a player URL.
    public func recordingMediaRequest(for file: ZoomRecordingFile, forceRefresh: Bool = false) async throws -> URLRequest {
        guard file.isPlayableVideo || file.isChatTranscript || file.isAudioTranscript, let url = file.mediaURL else {
            throw ZoomAccountError.recordingUnavailable
        }
        guard connectionTask == nil else { throw ZoomAccountError.authorizationInProgress }
        let expected = generation
        try requireGeneration(expected)
        let configuration = try await configuration()
        try requireGeneration(expected)
        let token = try await accessToken(configuration: configuration, generation: expected, forceRefresh: forceRefresh)
        try requireGeneration(expected)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func cancelCreationWaiter(_ waiterID: UUID, taskID: UUID, generation expected: UUID) {
        guard expected == generation && meetingCreationTaskID == taskID else { return }
        meetingCreationWaiters.remove(waiterID)
        if meetingCreationWaiters.isEmpty && !meetingCreationUnconfirmed && pendingHostedMeeting == nil {
            meetingCreationTask?.cancel()
        }
    }

    private func createInstantMeeting(title: String, generation expected: UUID) async throws -> Int64 {
        let configuration = try await configuration()
        try requireGeneration(expected)
        var token = try await accessToken(configuration: configuration, generation: expected)
        for attempt in 0...1 {
            try requireGeneration(expected)
            var request = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let topic = title.trimmingCharacters(in: .whitespacesAndNewlines)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": 1, "topic": topic.isEmpty ? "Zooom meeting" : String(topic.prefix(200)),
                "settings": ["host_video": false, "participant_video": false, "mute_upon_entry": true,
                    "join_before_host": false, "waiting_room": true, "auto_recording": "none",
                    "auto_start_meeting_summary": false, "auto_start_ai_companion_questions": false,
                    "use_pmi": false]
            ])
            // This POST has no documented idempotency key. After a network/ambiguous failure,
            // require an explicit reconnect rather than silently issuing another create.
            meetingCreationUnconfirmed = true
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch {
                try requireGeneration(expected)
                throw ZoomAccountError.meetingCreationUnconfirmed
            }
            try requireGeneration(expected)
            if (try? JSONDecoder().decode(ProviderErrorResponse.self, from: data).code) == 4711 {
                meetingCreationUnconfirmed = false
                throw ZoomAccountError.missingHostingScope
            }
            if response.statusCode == 401 {
                meetingCreationUnconfirmed = false
                guard attempt == 0 else { throw ZoomAccountError.notConnected }
                token = try await accessToken(configuration: configuration, generation: expected, forceRefresh: true)
                continue
            }
            if response.statusCode == 201 {
                guard let result = try? JSONDecoder().decode(CreatedMeetingResponse.self, from: data),
                      (100_000_000...99_999_999_999).contains(result.id) else {
                    throw ZoomAccountError.meetingCreationUnconfirmed
                }
                pendingHostedMeeting = result.id
                meetingCreationUnconfirmed = false
                return result.id
            }
            if response.statusCode >= 500 || (200..<300).contains(response.statusCode) {
                throw ZoomAccountError.meetingCreationUnconfirmed
            }
            meetingCreationUnconfirmed = false
            if response.statusCode == 403 { throw ZoomAccountError.missingHostingScope }
            try Self.checkStatus(response)
        }
        throw ZoomAccountError.notConnected
    }

    private func configuration() async throws -> ZoomPersonalConfiguration {
        if let storeMutationTask { _ = try? await storeMutationTask.value }
        guard let configuration = try await store.loadConfiguration(), configuration.isValid else {
            throw ZoomAccountError.notConfigured
        }
        return configuration
    }

    private func accessToken(configuration: ZoomPersonalConfiguration, generation expected: UUID,
                             forceRefresh: Bool = false) async throws -> String {
        try requireGeneration(expected)
        if let refreshTask {
            let updated = try await refreshTask.value
            try requireGeneration(expected)
            return updated.accessToken
        }
        let tokens: ZoomOAuthTokens?
        if let cachedTokens { tokens = cachedTokens }
        else { tokens = try await store.loadTokens() }
        try requireGeneration(expected)
        if let refreshTask {
            let updated = try await refreshTask.value
            try requireGeneration(expected)
            return updated.accessToken
        }
        guard let tokens, tokens.clientID == configuration.oauthPublicClientID else { throw ZoomAccountError.notConnected }
        if !forceRefresh && tokens.expiresAt.timeIntervalSinceNow > 60 {
            cachedTokens = tokens
            return tokens.accessToken
        }
        let currentGeneration = expected
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let updated = try await self.exchange(fields: ["grant_type": "refresh_token",
                "client_id": configuration.oauthPublicClientID, "refresh_token": tokens.refreshToken],
                clientID: configuration.oauthPublicClientID, previousRefreshToken: tokens.refreshToken)
            try await self.installTokens(updated, generation: currentGeneration)
            return updated
        }
        refreshTask = task
        do {
            let updated = try await task.value
            try requireGeneration(currentGeneration)
            if currentGeneration == generation { refreshTask = nil }
            return updated.accessToken
        } catch {
            if currentGeneration == generation {
                refreshTask = nil
                if error as? ZoomAccountError == .notConnected {
                    cachedTokens = nil
                    try? await mutateStore(generation: currentGeneration) { try await $0.deleteTokens() }
                }
            }
            throw error
        }
    }

    private func installTokens(_ tokens: ZoomOAuthTokens, generation expected: UUID) async throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        try await mutateStore(generation: expected) { try await $0.saveTokens(tokens) }
        guard generation == expected else { throw CancellationError() }
        if Task.isCancelled {
            cachedTokens = nil
            try? await mutateStore(generation: expected) { try await $0.deleteTokens() }
            throw CancellationError()
        }
        cachedTokens = tokens
    }

    private func exchange(fields: [String: String], clientID: String, previousRefreshToken: String?) async throws -> ZoomOAuthTokens {
        var request = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await transport.send(request)
        if response.statusCode == 400 || response.statusCode == 401 { throw ZoomAccountError.notConnected }
        try Self.checkStatus(response)
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !result.access_token.isEmpty, result.token_type.lowercased() == "bearer",
              result.expires_in > 0, result.expires_in <= 86_400,
              let refreshToken = result.refresh_token ?? previousRefreshToken, !refreshToken.isEmpty else {
            throw ZoomAccountError.invalidResponse
        }
        let scopes = Set(result.scope.split(separator: " ").map(String.init))
        guard scopes.contains(ZoomPersonalConfiguration.requiredScope) || scopes.contains("user_zak:read") else {
            throw ZoomAccountError.missingScope
        }
        return ZoomOAuthTokens(clientID: clientID, accessToken: result.access_token, refreshToken: refreshToken,
                               expiresAt: Date().addingTimeInterval(result.expires_in))
    }

    private func fetchZAK(accessToken: String) async throws -> FetchedZAK {
        try Task.checkCancellation()
        let requestStartedAt = Date()
        var request = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/zak")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 { throw ZoomAccountError.notConnected }
        if response.statusCode == 403 { throw ZoomAccountError.missingScope }
        try Self.checkStatus(response)
        guard let result = try? JSONDecoder().decode(ZAKResponse.self, from: data), !result.token.isEmpty else {
            throw ZoomAccountError.invalidResponse
        }
        // Count from request start so network latency never extends the reported five-minute validity.
        return FetchedZAK(token: result.token, expiresAt: requestStartedAt.addingTimeInterval(300))
    }

    /// Serialize credential mutations across suspension points. A disconnect waits for an
    /// already-started write before deleting it, so a delayed save cannot resurrect access.
    private func mutateStore(generation expected: UUID,
                             _ operation: @escaping @Sendable (any ZoomCredentialStore) async throws -> Void) async throws {
        let previous = storeMutationTask
        let store = store
        let task = Task { [weak self] in
            if let previous { _ = try? await previous.value }
            guard let self else { throw CancellationError() }
            try await self.requireGeneration(expected)
            try await operation(store)
        }
        storeMutationTask = task
        try await task.value
    }

    private func requireGeneration(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func cancelPendingOperations() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        cachedTokens = nil
        // A dispatched create may already have reached Zoom. Let it complete without
        // permitting its old account's result to become the new account's pending room.
        meetingCreationTask = nil
        meetingCreationTaskID = nil
        meetingCreationWaiters = []
        pendingHostedMeeting = nil
        meetingCreationUnconfirmed = false
    }

    private static func checkStatus(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 { throw ZoomAccountError.rateLimited }
        guard (200..<300).contains(response.statusCode) else { throw ZoomAccountError.rejected(response.statusCode) }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let token_type: String
        let expires_in: TimeInterval
        let scope: String
    }
    private struct ZAKResponse: Decodable { let token: String }
    private struct CreatedMeetingResponse: Decodable { let id: Int64 }
    private struct ProviderErrorResponse: Decodable { let code: Int }
    private struct FetchedZAK { let token: String; let expiresAt: Date }
}
