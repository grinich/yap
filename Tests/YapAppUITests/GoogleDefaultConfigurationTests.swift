import Foundation
import Testing
import YapCalendar
@testable import YapAppUI

@Suite("Bundled Google sign-in configuration")
struct GoogleDefaultConfigurationTests {
    private let bundled: [String: String] = [
        "YapGoogleClientID": "yap.apps.googleusercontent.com",
        "YapGoogleClientSecret": "desktop-client-secret"
    ]

    @Test func freshInstallCanSignInWithoutImportingCredentials() throws {
        let configuration = try YapConfigurationStore.resolveGoogle(savedData: { nil }, bundledInfo: bundled)
        #expect(configuration?.isValid == true)
        #expect(configuration?.clientID == "yap.apps.googleusercontent.com")
        #expect(configuration?.clientSecret == "desktop-client-secret")
    }

    @Test func packagedBuildUsesYapClientInsteadOfOldDeveloperConfiguration() throws {
        let saved = Data(#"{"installed":{"client_id":"custom.apps.googleusercontent.com","client_secret":"custom-secret"}}"#.utf8)
        let configuration = try YapConfigurationStore.resolveGoogle(savedData: { saved }, bundledInfo: bundled)
        #expect(configuration?.clientID == "yap.apps.googleusercontent.com")
        #expect(configuration?.clientSecret == "desktop-client-secret")
    }

    @Test func bundledConfigurationDoesNotReadLockedKeychain() throws {
        let configuration = try YapConfigurationStore.resolveGoogle(savedData: { throw GoogleCalendarError.keychain(-25308) }, bundledInfo: bundled)
        #expect(configuration?.clientID == "yap.apps.googleusercontent.com")
    }

    @Test func sourceBuildReportsInvalidImportedConfiguration() {
        #expect(throws: (any Error).self) {
            try YapConfigurationStore.resolveGoogle(savedData: { Data("invalid".utf8) }, bundledInfo: [:])
        }
    }

    @Test func sourceBuildCanStillUseDeveloperSetup() throws {
        #expect(try YapConfigurationStore.resolveGoogle(savedData: { nil }, bundledInfo: [:]) == nil)
        let data = Data(#"{"installed":{"client_id":"custom.apps.googleusercontent.com","client_secret":"custom-secret"}}"#.utf8)
        let configuration = try YapConfigurationStore.resolveGoogle(savedData: { data }, bundledInfo: [:])
        #expect(configuration?.clientID == "custom.apps.googleusercontent.com")
    }

    @Test func rejectsMalformedBundledClient() {
        #expect(throws: GoogleCalendarError.notConfigured) {
            try YapConfigurationStore.resolveGoogle(savedData: { nil }, bundledInfo: ["YapGoogleClientID": "invalid"])
        }
    }
}
