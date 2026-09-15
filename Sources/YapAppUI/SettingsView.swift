import SwiftUI
import AppKit
import YapSystem

public struct YapSettingsView: View {
    @Bindable var model: YapModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settings.selectedPane") private var selectedTab = 0
    public init(model: YapModel) { self.model = model }

    public var body: some View {
        TabView(selection: $selectedTab) {
            connections.tabItem { Label("Connections", systemImage: "person.crop.circle.badge.checkmark") }.tag(0)
            preferences.tabItem { Label("General", systemImage: "gearshape") }.tag(1)
            CameraEffectsSettingsView(effects: model.cameraEffects, connection: model.zoomConnection, isDemo: model.isPreview)
                .tabItem { Label("Camera", systemImage: "camera") }.tag(3)
            development.tabItem { Label("Development", systemImage: "hammer") }.tag(2)
        }
        .frame(width: 590, height: 600)
        .navigationTitle(selectedTab == 3 ? "Camera" : selectedTab == 1 ? "General" : selectedTab == 2 ? "Development" : "Connections")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshReminderAuthorization() }
        }
        .task { await model.refreshReminderAuthorization() }
        .sheet(isPresented: Binding(get: { model.showReminderPermission }, set: { if !$0 { model.cancelReminderSetup() } })) {
            ReminderPermissionView(model: model)
        }
    }

    private var connections: some View {
        Form {
            Section {
                HStack {
                    Label("Google Calendar", systemImage: "calendar")
                    Spacer()
                    Text(model.googleConfigurationLoadState == .loading ? "Loading…" : model.isCalendarConnected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                }
                if model.isCalendarConnected {
                    ForEach(model.calendars) { calendar in
                        Toggle(calendar.name, isOn: Binding(get: { model.selectedCalendarIDs.contains(calendar.id) }, set: { value in Task { await model.selectCalendar(calendar, selected: value) } }))
                            .toggleStyle(.checkbox)
                    }
                    Button("Disconnect Google Calendar", role: .destructive) { Task { await model.disconnectGoogle() } }
                } else {
                    Text("Read-only access to the calendars you select. Yap does not create, edit, or delete events.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(model.isConnecting ? "Waiting for Google…" : "Sign in with Google") {
                        Task { await model.connectGoogle() }
                    }
                    .disabled(model.isConnecting)
                    if model.isConnecting {
                        Button("Cancel sign-in") { Task { await model.disconnectGoogle() } }
                    }
                }
            } header: { Text("Your calendar") }
            ZoomConnectionView(model: model, connection: model.zoomConnection)
        }.formStyle(.grouped)
    }

    private var preferences: some View {
        Form {
            Section("In meetings") {
                HStack(spacing: 20) {
                    SettingsLabel(title: "Display name", detail: "How you appear to other people in meetings.")
                    Spacer(minLength: 0)
                    TextField("Your name", text: $model.displayName)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .multilineTextAlignment(.leading)
                        .frame(width: 190)
                        .accessibilityLabel("Display name")
                        .accessibilityIdentifier("settingsDisplayName")
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "video.slash")
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    SettingsLabel(title: "Join quietly", detail: "Your microphone and camera start off. Turn them on when you’re ready.")
                    Spacer(minLength: 0)
                }
                Toggle(isOn: $model.askBeforeLeavingMeeting) {
                    SettingsLabel(title: "Confirm before leaving", detail: "Ask whether to leave or end the meeting. When off, Leave exits only your call.")
                }
                .toggleStyle(.switch)
            }
            Section("Chat") {
                HStack(spacing: 20) {
                    SettingsLabel(title: "Message sound", detail: "Plays when a new message arrives while you aren’t viewing chat. The badge stays on with sound set to None.")
                    Spacer(minLength: 0)
                    SettingsChoiceMenu(title: "Message sound", selection: $model.chatNotificationSound,
                        choices: ChatNotificationSound.allCases.map { SettingsChoice(value: $0, title: $0.rawValue) })
                        .frame(width: 190)
                        .onChange(of: model.chatNotificationSound) { _, sound in sound.play() }
                }
            }
            ZoomLinkSettingsView()
            Section("Reminders") {
                Toggle(isOn: Binding(get: { model.remindersEnabled }, set: { enabled in
                    Task {
                        if enabled { await model.beginReminderSetup() }
                        else { await model.setReminders(false) }
                    }
                })) {
                    SettingsLabel(title: "Meeting reminders", detail: "Get a notification before your next meeting.")
                }
                .toggleStyle(.switch)
                .disabled(model.isChangingReminders || model.isPreview)
                if model.reminderAuthorizationStatus == .denied {
                    Text("Notifications are off in macOS. Turn on reminders to review the setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 20) {
                    SettingsLabel(title: "Remind me", detail: model.remindersEnabled
                        ? "Opens meeting details without turning on your camera or microphone."
                        : "Turn on meeting reminders to choose a time.")
                    Spacer(minLength: 0)
                    SettingsChoiceMenu(title: "Remind me", selection: $model.reminderMinutes, choices: [
                        SettingsChoice(value: 1, title: "1 minute before"),
                        SettingsChoice(value: 2, title: "2 minutes before"),
                        SettingsChoice(value: 5, title: "5 minutes before")
                    ])
                    .frame(width: 190)
                    .disabled(!model.remindersEnabled)
                    .onChange(of: model.reminderMinutes) { Task { await model.synchronizeReminders() } }
                }
            }
            LaunchAtLoginSettingsView()
        }.formStyle(.grouped)
    }

    private var development: some View {
        Form {
            Section(appVersionTitle) {
                Text("Interface preview uses sample people and messages on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.isPreview ? "Exit interface preview" : "Explore interface preview") {
                    Task {
                        if model.isPreview { await model.exitPreview() } else { model.enterPreview() }
                        openWindow(id: "main")
                        dismiss()
                    }
                }.disabled(model.activeCall)
            }
            Section("Video capacity") {
                Text("100+ participant layouts are a test target. Rendering sample tiles does not verify that Zoom can deliver 100 simultaneous live videos.")
                    .font(.callout).foregroundStyle(.secondary)
            }

        }.formStyle(.grouped)
    }

    private var appVersionTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "Yap" }
        return "Yap \(version)"
    }

}
