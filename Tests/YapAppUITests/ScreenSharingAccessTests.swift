import Testing
@testable import YapAppUI

@Suite("Screen sharing onboarding") @MainActor
struct ScreenSharingAccessTests {
    enum Denied: Error { case access }

    @Test func checksWithoutPromptingUntilUserRequestsAccess() async {
        var requests = 0
        var probes = 0
        let access = ScreenSharingAccess(preflight: { false }, request: { requests += 1 }, probe: { probes += 1 })
        await access.check()
        #expect(access.state == .needsAccess)
        #expect(requests == 0 && probes == 0)
        await access.check(ask: true)
        #expect(access.state == .ready)
        #expect(requests == 1 && probes == 1)
        await access.check(ask: true)
        #expect(requests == 1 && probes == 2)
    }

    @Test func recoversAfterSettingsEvenWhenPreflightIsStale() async {
        var available = false
        let access = ScreenSharingAccess(preflight: { false }, request: {}, probe: {
            if !available { throw Denied.access }
        })
        access.prepareForSettings()
        await access.check()
        #expect(access.state == .needsAccess)
        available = true
        await access.check()
        #expect(access.state == .ready)
    }

    @Test func enabledPermissionDoesNotPretendCaptureWorks() async {
        var available = false
        let access = ScreenSharingAccess(preflight: { true }, request: {}, probe: {
            if !available { throw Denied.access }
        })
        await access.check()
        #expect(access.state == .unavailable)
        available = true
        await access.check()
        #expect(access.state == .ready)
    }
}
