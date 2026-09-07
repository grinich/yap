import Foundation
import Testing
@testable import YapAppUI

@Suite("Bundle preference migration")
@MainActor
struct YapPreferenceMigrationTests {
    @Test func newIdentityMigratesThePreviousBundleBeforeTheOriginalPersonalApp() {
        #expect(YapPreferenceMigration.currentBundleIdentifier == "com.grinich.yap")
        #expect(YapPreferenceMigration.legacyBundleIdentifiers == ["com.grinich.zooom", "com.grinich.woosh", "com.grinich.whoosh", "app.whoosh.personal"])
        let result = YapPreferenceMigration.merging(current: [:], legacy: [
            "displayName": "Taylor", "zooom.migratedPreferences.v1": true
        ])
        #expect(result["displayName"] as? String == "Taylor")
        #expect(result[YapPreferenceMigration.completionKey] as? Bool == true)
        #expect(result["zooom.migratedPreferences.v1"] == nil)
    }

    @Test(arguments: [true, false])
    func usesOnlyTheMostRecentExistingDomain(recentDomainExists: Bool) throws {
        let unique = UUID().uuidString
        let domains = ["yap.preference-test.current.\(unique)",
                       "yap.preference-test.recent.\(unique)",
                       "yap.preference-test.original.\(unique)"]
        let preferences = try #require(UserDefaults(suiteName: domains[0]))
        defer { domains.forEach { preferences.removePersistentDomain(forName: $0) } }
        preferences.setPersistentDomain(["displayName": "Original", "selectedCalendarIDs": ["old"]], forName: domains[2])
        if recentDomainExists {
            preferences.setPersistentDomain(["displayName": "Recent", "whoosh.migratedPersonalPreferences.v1": true], forName: domains[1])
        }
        YapPreferenceMigration.migrate(preferences: preferences, currentDomain: domains[0], legacyDomains: Array(domains.dropFirst()))
        #expect(preferences.string(forKey: "displayName") == (recentDomainExists ? "Recent" : "Original"))
        // A missing selection in the newer domain must not resurrect an older selection.
        #expect(preferences.stringArray(forKey: "selectedCalendarIDs") == (recentDomainExists ? nil : ["old"]))
        #expect(preferences.persistentDomain(forName: domains[2])?["displayName"] as? String == "Original")
    }

    @Test func copiesOnlyTheFiveSupportedUserPreferences() {
        let result = YapPreferenceMigration.merging(current: [:], legacy: [
            "displayName": "Taylor", "selectedCalendarIDs": ["primary", "work"],
            "remindersEnabled": true, "reminderMinutes": 5, "settings.selectedPane": 2,
            "unrelated": "ignored", "sdkClientSecret": "not-a-preference", "NSWindow Frame Main": "ignored"
        ])
        #expect(result["displayName"] as? String == "Taylor")
        #expect(result["selectedCalendarIDs"] as? [String] == ["primary", "work"])
        #expect(result["remindersEnabled"] as? Bool == true)
        #expect(result["reminderMinutes"] as? Int == 5)
        #expect(result["settings.selectedPane"] as? Int == 2)
        #expect(result.count == 6)
        #expect(result[YapPreferenceMigration.completionKey] as? Bool == true)
    }

    @Test func existingFalseEmptyAndCustomValuesAreNeverOverwritten() {
        let current: [String: Any] = ["displayName": "", "selectedCalendarIDs": [String](),
                                     "remindersEnabled": false, "reminderMinutes": 10, "settings.selectedPane": 0, "newSetting": "keep"]
        let result = YapPreferenceMigration.merging(current: current, legacy: [
            "displayName": "Old", "selectedCalendarIDs": ["old"], "remindersEnabled": true, "reminderMinutes": 2, "settings.selectedPane": 2
        ])
        #expect(result["displayName"] as? String == "")
        #expect(result["selectedCalendarIDs"] as? [String] == [])
        #expect(result["remindersEnabled"] as? Bool == false)
        #expect(result["reminderMinutes"] as? Int == 10)
        #expect(result["settings.selectedPane"] as? Int == 0)
        #expect(result["newSetting"] as? String == "keep")
    }

    @Test func completedMigrationDoesNotRestoreRemovedPreferences() {
        let result = YapPreferenceMigration.merging(
            current: [YapPreferenceMigration.completionKey: true],
            legacy: ["displayName": "Old", "selectedCalendarIDs": ["old"]])
        #expect(result.count == 1)
        #expect(result["displayName"] == nil)
        #expect(result["selectedCalendarIDs"] == nil)
    }

    @Test func malformedLegacyTypesDoNotBecomePreferences() {
        let result = YapPreferenceMigration.merging(current: [:], legacy: [
            "displayName": 5, "selectedCalendarIDs": "primary", "remindersEnabled": 1,
            "reminderMinutes": true, "settings.selectedPane": 9
        ])
        #expect(result.count == 1)
        let fractional = YapPreferenceMigration.merging(current: [:], legacy: ["reminderMinutes": 1.5])
        #expect(fractional["reminderMinutes"] == nil)
    }

    @Test func migrationPersistsOnceAndLeavesTheOldDomainUntouched() throws {
        let unique = UUID().uuidString
        let currentName = "yap.preference-test.current.\(unique)"
        let oldName = "yap.preference-test.legacy.\(unique)"
        let preferences = try #require(UserDefaults(suiteName: currentName))
        defer {
            preferences.removePersistentDomain(forName: currentName)
            preferences.removePersistentDomain(forName: oldName)
        }
        preferences.setPersistentDomain(["displayName": "Legacy", "selectedCalendarIDs": [String]()], forName: oldName)
        YapPreferenceMigration.migrate(preferences: preferences, currentDomain: currentName, legacyDomain: oldName)
        #expect(preferences.string(forKey: "displayName") == "Legacy")
        #expect(preferences.stringArray(forKey: "selectedCalendarIDs") == [])
        preferences.removeObject(forKey: "displayName")
        YapPreferenceMigration.migrate(preferences: preferences, currentDomain: currentName, legacyDomain: oldName)
        #expect(preferences.object(forKey: "displayName") == nil)
        #expect(preferences.persistentDomain(forName: oldName)?["displayName"] as? String == "Legacy")
    }
}
