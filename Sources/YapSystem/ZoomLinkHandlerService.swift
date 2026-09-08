import AppKit
import Foundation

public enum ZoomLinkHandlerChoice: String, CaseIterable, Sendable {
    case yap, zoom

    public var displayName: String { self == .yap ? "Yap" : "Zoom Workplace" }
}

public enum ZoomLinkHandlerCurrent: Sendable, Equatable {
    case yap, zoom, mixed, other, unset
}

public struct ZoomLinkHandlerRegistration: Sendable, Equatable {
    public let scheme: String
    public let applicationURL: URL?
    public let bundleIdentifier: String?
}

public struct ZoomLinkHandlerStatus: Sendable, Equatable {
    public let handlers: [ZoomLinkHandlerRegistration]
    public let yapApplicationURL: URL?
    public let zoomApplicationURL: URL?

    public var current: ZoomLinkHandlerCurrent {
        if handlers.allSatisfy({ $0.applicationURL == nil }) { return .unset }
        if handlers.allSatisfy({ $0.bundleIdentifier == ZoomLinkHandlerService.yapBundleIdentifier }) { return .yap }
        if handlers.allSatisfy({ $0.bundleIdentifier == ZoomLinkHandlerService.zoomBundleIdentifier }) { return .zoom }
        let identities = handlers.map { $0.bundleIdentifier ?? $0.applicationURL?.standardizedFileURL.path }
        return Set(identities).count == 1 ? .other : .mixed
    }

    public func isApplied(_ choice: ZoomLinkHandlerChoice) -> Bool {
        guard let target = applicationURL(for: choice) else { return false }
        return handlers.allSatisfy {
            $0.applicationURL?.standardizedFileURL.resolvingSymlinksInPath()
                == target.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    public func applicationURL(for choice: ZoomLinkHandlerChoice) -> URL? {
        choice == .yap ? yapApplicationURL : zoomApplicationURL
    }
}

public struct ZoomLinkHandlerError: Error, LocalizedError, Sendable {
    public enum Reason: Sendable, Equatable {
        case applicationUnavailable(ZoomLinkHandlerChoice)
        case operationInProgress
        case cancelled
        case systemFailure(String)
        case notApplied
        case invalidLink
    }

    public let reason: Reason
    /// A fresh reading of macOS defaults after the operation and any restoration.
    public let status: ZoomLinkHandlerStatus
    public let restorationIncomplete: Bool

    public var errorDescription: String? {
        let message: String
        switch reason {
        case .applicationUnavailable(let choice):
            message = choice == .yap
                ? "Open the installed Yap app before selecting it to open Zoom links."
                : "Zoom Workplace is not installed. Install it before selecting it to open Zoom links."
        case .operationInProgress: message = "A Zoom link setting change is already in progress."
        case .cancelled: message = "The Zoom link action was cancelled."
        case .systemFailure(let detail): message = "macOS could not complete the Zoom link action. \(detail)"
        case .notApplied: message = "macOS did not apply the selected app to both Zoom link types."
        case .invalidLink: message = "This is not a Zoom meeting app link."
        }
        return restorationIncomplete
            ? message + " Some previous link settings could not be restored. The displayed selection reflects the current macOS settings."
            : message
    }
}

/// Reads the OS registration each time; it never keeps a separate saved preference.
/// Mutation and launching belong only behind explicit user actions.
@MainActor
public final class ZoomLinkHandlerService {
    public nonisolated static let yapBundleIdentifier = "com.grinich.yap"
    public nonisolated static let zoomBundleIdentifier = "us.zoom.xos"
    public nonisolated static let schemes = ["zoommtg", "zoomus"]

    struct Dependencies {
        var applicationURL: @MainActor (ZoomLinkHandlerChoice) -> URL?
        var handlerURL: @MainActor (String) -> URL?
        var bundleIdentifier: @MainActor (URL) -> String?
        var setHandler: @MainActor (URL, String) async throws -> Void
        var open: @MainActor (URL, URL) async throws -> Void
        var waitForRegistration: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private let dependencies: Dependencies
    private var isChanging = false

    public convenience init() {
        self.init(dependencies: Dependencies(
            applicationURL: { choice in
                switch choice {
                case .yap:
                    // Launch Services can know several worktrees with the same ID.
                    // Select this running app rather than an arbitrary copy.
                    Self.validApplicationURL(Bundle.main.bundleURL, identifier: Self.yapBundleIdentifier)
                case .zoom:
                    Self.validApplicationURL(
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.zoomBundleIdentifier),
                        identifier: Self.zoomBundleIdentifier
                    )
                }
            },
            handlerURL: { scheme in
                guard let url = URL(string: "\(scheme)://") else { return nil }
                return NSWorkspace.shared.urlForApplication(toOpen: url)
            },
            bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
            setHandler: { application, scheme in
                try await NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: scheme)
            },
            open: { url, application in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
            }
        ))
    }

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    public func status() -> ZoomLinkHandlerStatus {
        ZoomLinkHandlerStatus(
            handlers: Self.schemes.map { scheme in
                let url = dependencies.handlerURL(scheme)
                return ZoomLinkHandlerRegistration(scheme: scheme, applicationURL: url,
                    bundleIdentifier: url.flatMap(dependencies.bundleIdentifier))
            },
            yapApplicationURL: dependencies.applicationURL(.yap),
            zoomApplicationURL: dependencies.applicationURL(.zoom)
        )
    }

    @discardableResult
    public func select(_ choice: ZoomLinkHandlerChoice) async throws -> ZoomLinkHandlerStatus {
        let previous = status()
        guard !isChanging else { throw failure(.operationInProgress) }
        guard !Task.isCancelled else { throw failure(.cancelled) }
        guard let application = previous.applicationURL(for: choice) else {
            throw failure(.applicationUnavailable(choice))
        }
        isChanging = true
        defer { isChanging = false }
        var attemptedSchemes: Set<String> = []

        do {
            for scheme in Self.schemes {
                try Task.checkCancellation()
                if !Self.sameApplication(dependencies.handlerURL(scheme), application) {
                    attemptedSchemes.insert(scheme)
                    try await dependencies.setHandler(application, scheme)
                }
                try Task.checkCancellation()
            }
            // Launch Services can finish the request before its resolver sees
            // the new registration. Give readback a bounded settling period.
            let actual = try await settledStatus { $0.isApplied(choice) }
            guard actual.isApplied(choice) else {
                throw ZoomLinkHandlerError(reason: .notApplied, status: actual, restorationIncomplete: false)
            }
            return actual
        } catch {
            // This task may be cancelled, so perform cleanup in an uncancelled task.
            // Never overwrite a handler another app changed while our call awaited.
            await restore(previous.handlers.filter { attemptedSchemes.contains($0.scheme) }, replacing: application)
            let actual = await Task { @MainActor in
                (try? await settledStatus { current in
                    zip(previous.handlers, current.handlers).allSatisfy {
                        Self.sameApplication($0.0.applicationURL, $0.1.applicationURL)
                    }
                }) ?? status()
            }.value
            let incomplete = zip(previous.handlers, actual.handlers).contains {
                !Self.sameApplication($0.0.applicationURL, $0.1.applicationURL)
            }
            let reason: ZoomLinkHandlerError.Reason
            if error is CancellationError || Task.isCancelled { reason = .cancelled }
            else if let error = error as? ZoomLinkHandlerError { reason = error.reason }
            else { reason = .systemFailure(error.localizedDescription) }
            throw ZoomLinkHandlerError(reason: reason, status: actual, restorationIncomplete: incomplete)
        }
    }

    /// Launches the official app directly, bypassing these same URL defaults.
    public func openInZoom(_ url: URL) async throws {
        guard Self.schemes.contains(url.scheme?.lowercased() ?? "") else { throw failure(.invalidLink) }
        guard !Task.isCancelled else { throw failure(.cancelled) }
        guard let application = dependencies.applicationURL(.zoom) else { throw failure(.applicationUnavailable(.zoom)) }
        do {
            try await dependencies.open(url, application)
        } catch {
            throw failure(error is CancellationError || Task.isCancelled ? .cancelled : .systemFailure(error.localizedDescription))
        }
    }

    private func restore(_ original: [ZoomLinkHandlerRegistration], replacing target: URL) async {
        let dependencies = dependencies
        await Task { @MainActor in
            for handler in original.reversed() {
                guard !Self.sameApplication(handler.applicationURL, target),
                      Self.sameApplication(dependencies.handlerURL(handler.scheme), target),
                      let originalURL = handler.applicationURL else { continue }
                // NSWorkspace has no supported operation to restore an unset handler.
                // Errors are represented by the actual settings in the final report.
                try? await dependencies.setHandler(originalURL, handler.scheme)
            }
        }.value
    }

    private func settledStatus(matching predicate: (ZoomLinkHandlerStatus) -> Bool) async throws -> ZoomLinkHandlerStatus {
        var actual = status()
        for _ in 0..<20 {
            try Task.checkCancellation()
            if predicate(actual) { return actual }
            try await dependencies.waitForRegistration()
            actual = status()
        }
        return actual
    }

    private func failure(_ reason: ZoomLinkHandlerError.Reason) -> ZoomLinkHandlerError {
        ZoomLinkHandlerError(reason: reason, status: status(), restorationIncomplete: false)
    }

    private static func validApplicationURL(_ url: URL?, identifier: String) -> URL? {
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url.standardizedFileURL
    }

    private static func sameApplication(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL.resolvingSymlinksInPath() == rhs?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
