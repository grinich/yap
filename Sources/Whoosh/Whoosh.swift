import SwiftUI
import WhooshAppUI
import WhooshSystem
import AppIntents

@main
struct WhooshApplication: App {
    @NSApplicationDelegateAdaptor(WhooshApplicationDelegate.self) private var delegate
    @State private var model: WhooshModel

    init() {
        WhooshPreferenceMigration.migrateStandardPreferencesIfNeeded()
        _model = State(initialValue: WhooshModel())
    }

    var body: some Scene {
        Window("Agenda", id: "main") {
            WhooshRootView(model: model, applicationDelegate: delegate)
        }
        .defaultSize(width: 860, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { WhooshCommands(model: model) }

        Settings { WhooshSettingsView(model: model) }

    }
}

struct WhooshIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [WhooshSystemIntentPackage.self] }
}

public struct WhooshShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWhooshIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Zooom",
            systemImageName: "video"
        )
        AppShortcut(
            intent: ShowUpcomingMeetingsIntent(),
            phrases: ["Show upcoming meetings in \(.applicationName)"],
            shortTitle: "Upcoming Meetings",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: JoinNextMeetingIntent(),
            phrases: ["Join my next meeting in \(.applicationName)"],
            shortTitle: "Join Next Meeting",
            systemImageName: "video.badge.waveform"
        )
    }
}
