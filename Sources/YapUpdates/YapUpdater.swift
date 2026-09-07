import AppKit
import Combine
import Sparkle
import SwiftUI

/// Development builds and previews have no feed and never contact an update server.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(bundle: Bundle) {
        guard bundle.bundleIdentifier == "com.grinich.yap",
              bundle.bundleURL.pathExtension == "app" else { return nil }
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url
        publicKey = key
    }
}

/// Recheck at the moment of installation, including if a call began after download.
@MainActor
final class MeetingUpdateGate {
    private let isMeetingActive: () -> Bool

    init(isMeetingActive: @escaping () -> Bool) { self.isMeetingActive = isMeetingActive }
    var canInstall: Bool { !isMeetingActive() }

}

@MainActor
public final class YapUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published public private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var availability: AnyCancellable?
    private let gate: MeetingUpdateGate

    public init(isMeetingActive: @escaping () -> Bool) {
        gate = MeetingUpdateGate(isMeetingActive: isMeetingActive)
        super.init()
        guard UpdateConfiguration(bundle: .main) != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        availability = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
        controller.startUpdater()
    }

    public func checkForUpdates() {
        guard gate.canInstall else { return }
        controller?.checkForUpdates(nil)
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard gate.canInstall else {
            throw NSError(domain: "com.grinich.yap.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Yap will check for updates after your meeting."])
        }
    }

    // This is called even when Sparkle resumes a staged update on a later launch.
    // Vetoing leaves Yap running; the user can install after the call ends.
    public func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { gate.canInstall }
}

public struct YapUpdateCommands: Commands {
    @ObservedObject private var updater: YapUpdater
    private let meetingActive: Bool

    public init(updater: YapUpdater, meetingActive: Bool) {
        self.updater = updater
        self.meetingActive = meetingActive
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates || meetingActive)
            Divider()
        }
    }
}
