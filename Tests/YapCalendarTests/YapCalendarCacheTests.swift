import Foundation
import Testing
@testable import YapCalendar

@Suite("Renamed agenda cache")
struct YapCalendarCacheTests {
    @Test func resolvingAClientCacheLocationNeverCreatesDirectoriesOrMigratesData() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Whoosh/agenda.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("existing-private-agenda".utf8)
        try contents.write(to: legacy)

        let url = YapCalendarCache.url(in: root, bundleIdentifier: "com.grinich.yap", bundleURL: URL(filePath: "/Applications/Yap.app"))

        #expect(url == root.appendingPathComponent("Yap/agenda.json"))
        #expect(try Data(contentsOf: legacy) == contents)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Yap").path))
    }

    @Test func previewUnbundledAndDisconnectedContextsCannotTouchTheInstalledAppCache() throws {
        let app = URL(filePath: "/Applications/Yap.app")
        let contexts: [(String?, URL, Bool, Bool)] = [
            ("com.grinich.yap", app, true, true),
            ("com.grinich.yap", app, false, false),
            (nil, URL(filePath: "/tmp/test-runner"), false, true),
            ("com.grinich.yap", URL(filePath: "/tmp/Yap"), false, true),
            ("com.grinich.zooom", app, false, true)
        ]
        for (identifier, bundle, preview, credentials) in contexts {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let legacy = root.appendingPathComponent("Whoosh/agenda.json")
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = Data("untouched-agenda".utf8)
            try contents.write(to: legacy)

            let result = try YapCalendarCache.prepareForLiveApp(in: root, bundleIdentifier: identifier, bundleURL: bundle,
                isPreview: preview, hasCredentials: credentials)

            #expect(result == nil)
            #expect(try Data(contentsOf: legacy) == contents)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Yap").path))
        }
    }

    @Test func leavingPreviewForAConnectedLiveAppPerformsTheDeferredMigration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Whoosh/agenda.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("connection-bound-agenda".utf8)
        try contents.write(to: legacy)
        let app = URL(filePath: "/Applications/Yap.app")
        #expect(try YapCalendarCache.prepareForLiveApp(in: root, bundleIdentifier: "com.grinich.yap", bundleURL: app,
            isPreview: true, hasCredentials: true) == nil)

        let migrated = try YapCalendarCache.prepareForLiveApp(in: root, bundleIdentifier: "com.grinich.yap", bundleURL: app,
            isPreview: false, hasCredentials: true)
        let result = try #require(migrated)

        #expect(try Data(contentsOf: result) == contents)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Yap/.migrated-legacy-agenda-v1").path))
    }

    @Test func movesLegacyCacheOnceAndKeepsPrivatePermissions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Whoosh/agenda.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("connection-bound-cache".utf8).write(to: legacy)

        let cache = try YapCalendarCache.prepare(in: root)

        #expect(cache == root.appendingPathComponent("Yap/agenda.json"))
        #expect(try Data(contentsOf: cache) == Data("connection-bound-cache".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.removeItem(at: cache)
        try Data("stale-cache-from-old-app".utf8).write(to: legacy)
        _ = try YapCalendarCache.prepare(in: root)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func existingYapCacheAndItsLaterRemovalNeverFallBackToPreviousApp() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Whoosh/agenda.json")
        let current = root.appendingPathComponent("Yap/agenda.json")
        for file in [legacy, current] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: legacy)
        try Data("current".utf8).write(to: current)
        _ = try YapCalendarCache.prepare(in: root)
        #expect(try Data(contentsOf: current) == Data("current".utf8))
        try FileManager.default.removeItem(at: current)
        _ = try YapCalendarCache.prepare(in: root)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test func firstLaunchWithoutLegacyCacheDoesNotImportOneCreatedLater() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try YapCalendarCache.prepare(in: root)
        let legacy = root.appendingPathComponent("Whoosh/agenda.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("later-old-cache".utf8).write(to: legacy)
        _ = try YapCalendarCache.prepare(in: root)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yap-cache-migration-\(UUID().uuidString)")
    }
}
