import Foundation
import CoreFoundation

/// Preserve supported preferences across the app's bundle identity changes.
/// Credential keys, macOS permissions, login items, and SDK state are separate.
@MainActor
public enum WhooshPreferenceMigration {
    static let currentBundleIdentifier = "com.grinich.zooom"
    static let legacyBundleIdentifiers = ["com.grinich.woosh", "app.whoosh.personal"]
    static let completionKey = "zooom.migratedPreferences.v1"

    /// Call from the app entry point before constructing WhooshModel. This
    /// cannot run in a preview/test executable or against an injected suite.
    public static func migrateStandardPreferencesIfNeeded() {
        guard Bundle.main.bundleIdentifier == currentBundleIdentifier else { return }
        migrate(preferences: .standard, currentDomain: currentBundleIdentifier,
                legacyDomains: legacyBundleIdentifiers)
    }

    static func migrate(preferences: UserDefaults, currentDomain: String, legacyDomain: String) {
        migrate(preferences: preferences, currentDomain: currentDomain, legacyDomains: [legacyDomain])
    }

    static func migrate(preferences: UserDefaults, currentDomain: String, legacyDomains: [String]) {
        let current = preferences.persistentDomain(forName: currentDomain) ?? [:]
        guard current[completionKey] as? Bool != true else { return }
        // Use the most recent existing domain as a whole. Falling back per key
        // could restore a preference the user removed in the newer app.
        let legacy = legacyDomains.lazy.compactMap { preferences.persistentDomain(forName: $0) }.first ?? [:]
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
