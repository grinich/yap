import Foundation
import CoreFoundation

/// The bundle identity changes once; the personal preference values do not.
/// Credential keys, macOS permissions, login items, and SDK state are separate.
@MainActor
public enum WhooshPreferenceMigration {
    static let currentBundleIdentifier = "com.grinich.woosh"
    static let legacyBundleIdentifier = "app.whoosh.personal"
    static let completionKey = "whoosh.migratedPersonalPreferences.v1"

    /// Call from the app entry point before constructing WhooshModel. This
    /// cannot run in a preview/test executable or against an injected suite.
    public static func migrateStandardPreferencesIfNeeded() {
        guard Bundle.main.bundleIdentifier == currentBundleIdentifier else { return }
        migrate(preferences: .standard, currentDomain: currentBundleIdentifier,
                legacyDomain: legacyBundleIdentifier)
    }

    static func migrate(preferences: UserDefaults, currentDomain: String, legacyDomain: String) {
        let current = preferences.persistentDomain(forName: currentDomain) ?? [:]
        guard current[completionKey] as? Bool != true else { return }
        let legacy = preferences.persistentDomain(forName: legacyDomain) ?? [:]
        preferences.setPersistentDomain(merging(current: current, legacy: legacy), forName: currentDomain)
    }

    static func merging(current: [String: Any], legacy: [String: Any]) -> [String: Any] {
        guard current[completionKey] as? Bool != true else { return current }
        var result = current
        if current["displayName"] == nil, let value = legacy["displayName"] as? String {
            result["displayName"] = value
        }
        if current["selectedCalendarIDs"] == nil, let value = legacy["selectedCalendarIDs"] as? [String] {
            result["selectedCalendarIDs"] = value
        }
        if current["remindersEnabled"] == nil, let value = legacy["remindersEnabled"] as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() {
            result["remindersEnabled"] = value.boolValue
        }
        if current["reminderMinutes"] == nil, let value = legacy["reminderMinutes"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
           value.doubleValue >= 1, value.doubleValue < Double(Int.max),
           value.doubleValue.rounded(.towardZero) == value.doubleValue {
            result["reminderMinutes"] = value.intValue
        }
        if current["settings.selectedPane"] == nil, let value = legacy["settings.selectedPane"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), (0...2).contains(value.doubleValue),
           value.doubleValue.rounded(.towardZero) == value.doubleValue {
            result["settings.selectedPane"] = value.intValue
        }
        result[completionKey] = true
        return result
    }
}
