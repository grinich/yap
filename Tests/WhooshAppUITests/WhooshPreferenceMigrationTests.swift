import Foundation
import Testing
@testable import WhooshAppUI

@Suite("Personal bundle preference migration")
@MainActor
struct WhooshPreferenceMigrationTests {
    @Test func copiesOnlyTheFiveSupportedUserPreferences() {
        let result = WhooshPreferenceMigration.merging(current: [:], legacy: [
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
        #expect(result[WhooshPreferenceMigration.completionKey] as? Bool == true)
    }

    @Test func existingFalseEmptyAndCustomValuesAreNeverOverwritten() {
        let current: [String: Any] = ["displayName": "", "selectedCalendarIDs": [String](),
                                     "remindersEnabled": false, "reminderMinutes": 10, "settings.selectedPane": 0, "newSetting": "keep"]
        let result = WhooshPreferenceMigration.merging(current: current, legacy: [
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
        let result = WhooshPreferenceMigration.merging(
            current: [WhooshPreferenceMigration.completionKey: true],
            legacy: ["displayName": "Old", "selectedCalendarIDs": ["old"]])
        #expect(result.count == 1)
        #expect(result["displayName"] == nil)
        #expect(result["selectedCalendarIDs"] == nil)
    }

    @Test func malformedLegacyTypesDoNotBecomePreferences() {
        let result = WhooshPreferenceMigration.merging(current: [:], legacy: [
            "displayName": 5, "selectedCalendarIDs": "primary", "remindersEnabled": 1,
            "reminderMinutes": true, "settings.selectedPane": 9
        ])
        #expect(result.count == 1)
        let fractional = WhooshPreferenceMigration.merging(current: [:], legacy: ["reminderMinutes": 1.5])
        #expect(fractional["reminderMinutes"] == nil)
    }

    @Test func migrationPersistsOnceAndLeavesTheOldDomainUntouched() throws {
        let unique = UUID().uuidString
        let currentName = "whoosh.preference-test.current.\(unique)"
        let oldName = "whoosh.preference-test.legacy.\(unique)"
        let preferences = try #require(UserDefaults(suiteName: currentName))
        defer {
            preferences.removePersistentDomain(forName: currentName)
            preferences.removePersistentDomain(forName: oldName)
        }
        preferences.setPersistentDomain(["displayName": "Legacy", "selectedCalendarIDs": [String]()], forName: oldName)
        WhooshPreferenceMigration.migrate(preferences: preferences, currentDomain: currentName, legacyDomain: oldName)
        #expect(preferences.string(forKey: "displayName") == "Legacy")
        #expect(preferences.stringArray(forKey: "selectedCalendarIDs") == [])
        preferences.removeObject(forKey: "displayName")
        WhooshPreferenceMigration.migrate(preferences: preferences, currentDomain: currentName, legacyDomain: oldName)
        #expect(preferences.object(forKey: "displayName") == nil)
        #expect(preferences.persistentDomain(forName: oldName)?["displayName"] as? String == "Legacy")
    }
}
