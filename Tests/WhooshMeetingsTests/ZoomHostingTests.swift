import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Zoom REST hosting preparation")
struct ZoomHostingTests {
    @Test func createsAnOwnAccountInstantRoomWithPrivateMediaDefaults() async throws {
        let server = HostingFixtureServer()
        let client = fixtureClient(server: server)
        let result = try await client.hostingCredentials(title: "Fixture room")
        #expect(result.meetingNumber == 999_888_777)
        #expect(result.credentials.zak.hasPrefix("fixture-host-zak-"))
        #expect(result.credentials.sdkJWT.split(separator: ".").count == 3)
        #expect(!result.description.contains("999888777"))
        #expect(!result.description.contains(result.credentials.zak))
        #expect(!result.debugDescription.contains(result.credentials.sdkJWT))

        let requests = await server.requests
        let creation = try #require(requests.first { $0.httpMethod == "POST" })
        #expect(creation.url?.absoluteString == "https://api.zoom.us/v2/users/me/meetings")
        #expect(creation.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-host-access")
        #expect(creation.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let data = try #require(creation.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? Int == 1)
        #expect(object["topic"] as? String == "Fixture room")
        #expect(object["schedule_for"] == nil)
        let settings = try #require(object["settings"] as? [String: Any])
        for key in ["host_video", "participant_video", "join_before_host", "auto_start_meeting_summary", "auto_start_ai_companion_questions", "use_pmi"] {
            #expect(settings[key] as? Bool == false, "Unsafe or absent room setting: \(key)")
        }
        #expect(settings["mute_upon_entry"] as? Bool == true)
        #expect(settings["waiting_room"] as? Bool == true)
        #expect(settings["auto_recording"] as? String == "none")
        #expect(settings["meeting_invitees"] == nil)
        #expect(String(data: data, encoding: .utf8)?.contains("fixture-host-secret") == false)
        #expect(requests.allSatisfy { $0.url?.host == "api.zoom.us" && ["/v2/users/me/meetings", "/v2/users/me/zak"].contains($0.url?.path ?? "") })
    }

    @Test func concurrentPreparationsAndLaterRetriesReuseOneRoom() async throws {
        let server = HostingFixtureServer(pauseFirstCreation: true)
        let client = fixtureClient(server: server)
        let first = Task { try await client.hostingCredentials(title: "Fixture room") }
        let second = Task { try await client.hostingCredentials(title: "Fixture room") }
        await server.waitForCreation()
        await server.releaseCreation()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.meetingNumber == secondResult.meetingNumber)
        let retry = try await client.hostingCredentials(title: "Retry the prepared room")
        #expect(retry.meetingNumber == firstResult.meetingNumber)
        #expect(await server.creationCount == 1)
        #expect(retry.credentials.zak != firstResult.credentials.zak)
    }

    @Test func onlyMatchingConfirmedStartAllowsAnotherRoomToBeCreated() async throws {
        let server = HostingFixtureServer()
        let client = fixtureClient(server: server)
        let prepared = try await client.hostingCredentials(title: "First room")
        await client.markHostedMeetingStarted(prepared.meetingNumber + 10)
        let retry = try await client.hostingCredentials(title: "Retry first room")
        #expect(retry.meetingNumber == prepared.meetingNumber)
        #expect(await server.creationCount == 1)
        await client.markHostedMeetingStarted(prepared.meetingNumber)
        let next = try await client.hostingCredentials(title: "Next room")
        #expect(next.meetingNumber != prepared.meetingNumber)
        #expect(await server.creationCount == 2)
    }

    @Test(arguments: [400, 401, 403])
    func missingOwnMeetingWriteScopeIsActionableAndRedacted(status: Int) async throws {
        let server = HostingFixtureServer(outcomes: [.response(status, Data(#"{"code":4711,"message":"fixture-private-response-marker"}"#.utf8))])
        let client = fixtureClient(server: server)
        await #expect(throws: ZoomAccountError.missingHostingScope) {
            try await client.hostingCredentials(title: "Fixture room")
        }
        #expect(await server.creationCount == 1)
        #expect(!ZoomAccountError.missingHostingScope.localizedDescription.contains("fixture-private-response-marker"))
    }

    @Test func aNetworkFailureCannotTriggerRepeatedCreation() async throws {
        let server = HostingFixtureServer(outcomes: [.networkFailure])
        let client = fixtureClient(server: server)
        for _ in 0..<2 {
            await #expect(throws: ZoomAccountError.meetingCreationUnconfirmed) {
                try await client.hostingCredentials(title: "Fixture room")
            }
        }
        #expect(await server.creationCount == 1)
    }

    @Test(arguments: [500, 502, 503])
    func aServerFailureCannotTriggerRepeatedCreation(status: Int) async throws {
        let server = HostingFixtureServer(outcomes: [.response(status, Data(#"{"message":"fixture-private-response-marker"}"#.utf8))])
        let client = fixtureClient(server: server)
        for _ in 0..<2 {
            await #expect(throws: ZoomAccountError.meetingCreationUnconfirmed) {
                try await client.hostingCredentials(title: "Fixture room")
            }
        }
        #expect(await server.creationCount == 1)
        #expect(!ZoomAccountError.meetingCreationUnconfirmed.localizedDescription.contains("fixture-private-response-marker"))
    }

    @Test(arguments: ["not-json", "{}", #"{"id":0}"#, #"{"id":-1}"#])
    func anInvalidSuccessCannotTriggerRepeatedCreation(body: String) async throws {
        let server = HostingFixtureServer(outcomes: [.response(201, Data(body.utf8))])
        let client = fixtureClient(server: server)
        for _ in 0..<2 {
            await #expect(throws: ZoomAccountError.meetingCreationUnconfirmed) {
                try await client.hostingCredentials(title: "Fixture room")
            }
        }
        #expect(await server.creationCount == 1)
    }

    @Test func cancellationAfterDispatchRetainsTheConfirmedRoomForRetry() async throws {
        let server = HostingFixtureServer(pauseFirstCreation: true)
        let client = fixtureClient(server: server)
        let cancelled = Task { try await client.hostingCredentials(title: "Fixture room") }
        await server.waitForCreation()
        cancelled.cancel()
        await server.releaseCreation()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let retry = try await client.hostingCredentials(title: "Retry after cancellation")
        #expect(retry.meetingNumber == 999_888_777)
        #expect(await server.creationCount == 1)
    }

    private func fixtureClient(server: HostingFixtureServer) -> ZoomAccountClient {
        ZoomAccountClient(store: HostingFixtureStore(), transport: ZoomHTTPTransport { try await server.send($0) })
    }
}

private actor HostingFixtureStore: ZoomCredentialStore {
    private var configuration: ZoomPersonalConfiguration? = ZoomPersonalConfiguration(
        sdkClientID: "fixture-host-sdk", sdkClientSecret: "fixture-host-secret", oauthPublicClientID: "fixture-host-public")
    private var tokens: ZoomOAuthTokens? = ZoomOAuthTokens(clientID: "fixture-host-public", accessToken: "fixture-host-access",
                                                          refreshToken: "fixture-host-refresh", expiresAt: Date().addingTimeInterval(3_600))
    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) { configuration = value }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ value: ZoomOAuthTokens) { tokens = value }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
}

private enum HostingFixtureOutcome: Sendable {
    case response(Int, Data)
    case networkFailure
}

private enum HostingFixtureError: Error { case unexpectedRequest }

private actor HostingFixtureServer {
    private(set) var requests: [URLRequest] = []
    private(set) var creationCount = 0
    private var zakCount = 0
    private var outcomes: [HostingFixtureOutcome]
    private var pauseFirstCreation: Bool
    private var creationGate: CheckedContinuation<Void, Never>?
    private var creationStarted: CheckedContinuation<Void, Never>?

    init(outcomes: [HostingFixtureOutcome] = [], pauseFirstCreation: Bool = false) {
        self.outcomes = outcomes
        self.pauseFirstCreation = pauseFirstCreation
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, url.host == "api.zoom.us" else { throw HostingFixtureError.unexpectedRequest }
        if url.path == "/v2/users/me/zak", (request.httpMethod ?? "GET") == "GET" {
            zakCount += 1
            let data = try JSONSerialization.data(withJSONObject: ["token": "fixture-host-zak-\(zakCount)"])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard url.path == "/v2/users/me/meetings", request.httpMethod == "POST" else { throw HostingFixtureError.unexpectedRequest }
        creationCount += 1
        let outcome: HostingFixtureOutcome = outcomes.isEmpty
            ? .response(201, try JSONSerialization.data(withJSONObject: ["id": 999_888_776 + creationCount]))
            : outcomes.removeFirst()
        if pauseFirstCreation {
            pauseFirstCreation = false
            await withCheckedContinuation { continuation in
                creationGate = continuation
                creationStarted?.resume()
                creationStarted = nil
            }
        }
        switch outcome {
        case .networkFailure: throw ZoomAccountError.network
        case .response(let status, let data):
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func waitForCreation() async {
        if creationGate != nil { return }
        await withCheckedContinuation { creationStarted = $0 }
    }

    func releaseCreation() { creationGate?.resume(); creationGate = nil }
}
