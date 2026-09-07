import Foundation

/// Moves only the previous app's derived agenda cache. The calendar client still
/// verifies its OAuth client and connection ID before showing any cached event.
public enum YapCalendarCache {
    /// Resolving a client’s cache location must never create or migrate files.
    /// Preview/test executables also must not use the installed app’s cache.
    public static func url(in applicationSupport: URL, bundleIdentifier: String?, bundleURL: URL) -> URL? {
        guard bundleIdentifier == "com.grinich.yap", bundleURL.pathExtension.lowercased() == "app" else { return nil }
        return applicationSupport.appendingPathComponent("Yap", isDirectory: true).appendingPathComponent("agenda.json")
    }

    /// Run only when the app actually starts loading a connected, live calendar.
    /// Configuration import and preview construction alone never migrate data.
    @discardableResult
    public static func prepareForLiveApp(in applicationSupport: URL, bundleIdentifier: String?, bundleURL: URL,
                                        isPreview: Bool, hasCredentials: Bool) throws -> URL? {
        guard !isPreview, hasCredentials,
              url(in: applicationSupport, bundleIdentifier: bundleIdentifier, bundleURL: bundleURL) != nil else { return nil }
        return try prepare(in: applicationSupport)
    }

    public static func prepare(in applicationSupport: URL) throws -> URL {
        let directory = applicationSupport.appendingPathComponent("Yap", isDirectory: true)
        let cache = directory.appendingPathComponent("agenda.json")
        let marker = directory.appendingPathComponent(".migrated-legacy-agenda-v1")
        let files = FileManager.default
        if files.fileExists(atPath: marker.path) { return cache }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let legacy = applicationSupport.appendingPathComponent("Whoosh", isDirectory: true)
            .appendingPathComponent("agenda.json")
        if !files.fileExists(atPath: cache.path), files.fileExists(atPath: legacy.path) {
            // Moving, rather than copying, prevents a later disconnect from
            // rediscovering this stale cache if the new cache has been cleared.
            try files.moveItem(at: legacy, to: cache)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        }
        // Mark even an absent legacy cache or an existing Yap cache, so a future
        // launch of the old app can never overwrite Yap's current cache choice.
        guard files.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return cache
    }
}
