import SwiftUI
import YapAppUI
import YapSystem
import YapUpdates
import AppIntents

@main
struct YapApplication: App {
    @NSApplicationDelegateAdaptor(YapApplicationDelegate.self) private var delegate
    @State private var model: YapModel
    @StateObject private var updater: YapUpdater

    init() {
        YapPreferenceMigration.migrateStandardPreferencesIfNeeded()
        let model = YapModel()
        _model = State(initialValue: model)
        _updater = StateObject(wrappedValue: YapUpdater(isMeetingActive: { model.activeCall }))
    }

    var body: some Scene {
        Window("Agenda", id: "main") {
            YapRootView(model: model, applicationDelegate: delegate)
        }
        .defaultSize(width: 860, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            YapCommands(model: model)
            YapUpdateCommands(updater: updater, meetingActive: model.activeCall)
        }

        Settings { YapSettingsView(model: model) }

    }
}

struct YapIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [YapSystemIntentPackage.self] }
}

public struct YapShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenYapIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Yap",
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
