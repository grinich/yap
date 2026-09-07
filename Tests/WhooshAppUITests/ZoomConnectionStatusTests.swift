import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Zoom saved connection status") @MainActor
struct ZoomConnectionStatusTests {
    @Test func firstReadIsLoadingAndCannotReplaceUnknownCredentials() async throws {
        let store = ZoomStatusFixtureStore(pausedReads: [1])
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let read = Task { await model.loadStatus() }
        await store.waitForPause(1)
        #expect(model.isLoadingStatus)
        #expect(!model.hasLoadedStatus)
        #expect(!model.isBusy)
        #expect(!(await model.saveConfiguration(ZoomStatusFixtureStore.fixtureConfiguration)))
        #expect(await store.saveCount == 0)
        await store.resumeRead(1)
        await read.value
        #expect(!model.isLoadingStatus)
        #expect(model.hasLoadedStatus)
        #expect(model.isConfigured)
        #expect(model.hasSavedConnection)
    }

    @Test func backgroundReadKeepsTheKnownConnectionUsable() async throws {
        let store = ZoomStatusFixtureStore()
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        await model.loadStatus()
        let nextRead = await store.pauseNextRead()
        let refresh = Task { await model.loadStatus() }
        await store.waitForPause(nextRead)
        #expect(model.isLoadingStatus)
        #expect(model.hasLoadedStatus)
        #expect(model.isConfigured)
        #expect(model.hasSavedConnection)
        // WhooshModel gates joining on isBusy, not on this read-only refresh.
        #expect(!model.isBusy)
        await store.resumeRead(nextRead)
        await refresh.value
        #expect(!model.isLoadingStatus)
        #expect(model.hasSavedConnection)
    }

    @Test func aDeniedFirstReadOffersRetryInsteadOfClaimingSetupIsMissing() async throws {
        let store = ZoomStatusFixtureStore(failFirstRead: true)
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        await model.loadStatus()
        #expect(!model.isLoadingStatus)
        #expect(!model.hasLoadedStatus)
        #expect(model.statusError != nil)
        await model.loadStatus()
        #expect(model.hasLoadedStatus)
        #expect(model.hasSavedConnection)
        #expect(model.statusError == nil)
        #expect(model.error == nil)
    }

    @Test func anOlderCompletionCannotEndANewerStatusCheck() async throws {
        let store = ZoomStatusFixtureStore(pausedReads: [1, 2])
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let older = Task { await model.loadStatus() }
        await store.waitForPause(1)
        let newer = Task { await model.loadStatus() }
        await store.waitForPause(2)
        await store.resumeRead(1)
        await older.value
        #expect(model.isLoadingStatus)
        #expect(!model.hasLoadedStatus)
        await store.resumeRead(2)
        await newer.value
        #expect(!model.isLoadingStatus)
        #expect(model.hasLoadedStatus)
        #expect(model.hasSavedConnection)
    }

    @Test func anInterruptedInitialReadCanBeRetried() async throws {
        let store = ZoomStatusFixtureStore(pausedReads: [1])
        let model = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let read = Task { await model.loadStatus() }
        await store.waitForPause(1)
        read.cancel()
        await store.resumeRead(1)
        await read.value
        #expect(!model.isLoadingStatus)
        #expect(!model.hasLoadedStatus)
        #expect(model.statusError != nil)
        await model.loadStatus()
        #expect(model.hasSavedConnection)
        #expect(model.statusError == nil)
    }
}

private actor ZoomStatusFixtureStore: ZoomCredentialStore {
    static let fixtureConfiguration = ZoomPersonalConfiguration(sdkClientID: "fixture-status-sdk", sdkClientSecret: "fixture-status-secret", oauthPublicClientID: "fixture-status-public")
    private var configuration: ZoomPersonalConfiguration? = fixtureConfiguration
    private var tokens: ZoomOAuthTokens? = ZoomOAuthTokens(clientID: "fixture-status-public", accessToken: "fixture-status-access", refreshToken: "fixture-status-refresh", expiresAt: Date().addingTimeInterval(3_600))
    private var pausedReads: Set<Int>
    private var failFirstRead: Bool
    private var readCount = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var saveCount = 0

    init(pausedReads: Set<Int> = [], failFirstRead: Bool = false) {
        self.pausedReads = pausedReads
        self.failFirstRead = failFirstRead
    }

    func loadConfiguration() async throws -> ZoomPersonalConfiguration? {
        readCount += 1
        let currentRead = readCount
        if failFirstRead {
            failFirstRead = false
            throw ZoomAccountError.keychain(-1)
        }
        if pausedReads.remove(currentRead) != nil {
            await withCheckedContinuation { continuation in
                gates[currentRead] = continuation
                waiters.removeValue(forKey: currentRead)?.resume()
            }
        }
        return configuration
    }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) { saveCount += 1; self.configuration = configuration }
    func loadTokens() -> ZoomOAuthTokens? { tokens }
    func saveTokens(_ tokens: ZoomOAuthTokens) { self.tokens = tokens }
    func deleteTokens() { tokens = nil }
    func deleteAll() { configuration = nil; tokens = nil }
    func pauseNextRead() -> Int { pausedReads.insert(readCount + 1); return readCount + 1 }
    func waitForPause(_ number: Int) async {
        if gates[number] != nil { return }
        await withCheckedContinuation { waiters[number] = $0 }
    }
    func resumeRead(_ number: Int) { gates.removeValue(forKey: number)?.resume() }
}
