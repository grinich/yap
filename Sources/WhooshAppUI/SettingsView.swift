import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhooshSystem

public struct WhooshSettingsView: View {
    @Bindable var model: WhooshModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settings.selectedPane") private var selectedTab = 0
    @State private var loginStatus = LaunchAtLoginService.status
    @State private var isChangingLogin = false
    public init(model: WhooshModel) { self.model = model }

    public var body: some View {
        TabView(selection: $selectedTab) {
            connections.tabItem { Label("Connections", systemImage: "person.crop.circle.badge.checkmark") }.tag(0)
            preferences.tabItem { Label("General", systemImage: "gearshape") }.tag(1)
            development.tabItem { Label("Development", systemImage: "hammer") }.tag(2)
        }
        .frame(width: 590, height: 560)
        .navigationTitle(selectedTab == 1 ? "General" : selectedTab == 2 ? "Development" : "Connections")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LaunchAtLoginService.status
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
                    Text("Read-only access to the calendars you select. Zooom does not create, edit, or delete events.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.googleConfigurationLoadState == .loading {
                        ProgressView("Loading your saved Google connection…")
                        Text("If macOS asks for Keychain access, respond in its dialog. You can keep using Zooom while it waits.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Continue without calendar") { model.cancelGoogleConfigurationLoad() }
                    } else if model.googleConfigurationLoadState == .pending || model.googleConfigurationLoadState == .cancelled || model.googleConfigurationLoadState == .failed {
                        Text("Your saved Google connection hasn’t been loaded.").font(.callout)
                        Button("Load saved Google connection") { Task { await model.loadGoogleConnection() } }
                        Button("Import Google desktop client…") { importGoogle() }
                    } else if model.googleConfigured {
                        Button(model.isConnecting ? "Waiting for Google…" : "Sign in with Google") { Task { await model.connectGoogle() } }
                            .disabled(model.isConnecting)
                        if model.isConnecting {
                            Button("Cancel sign-in") { Task { await model.disconnectGoogle() } }
                        }
                    } else {
                        Text("Your personal Google connection needs its initial developer setup.").font(.callout)
                        Button("Import Google desktop client…") { importGoogle() }
                            .disabled(model.isConnecting)
                        Link("Open Google Cloud setup", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                    }
                }
            } header: { Text("Your calendar") }
            ZoomConnectionView(model: model, connection: model.zoomConnection)
        }.formStyle(.grouped)
    }

    private var preferences: some View {
        Form {
            Section("In meetings") {
                TextField("Display name", text: $model.displayName)
                Label("Join with microphone muted and camera off", systemImage: "mic.slash")
                Text("Turn them on when you’re ready, using the call controls.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Reminders") {
                Toggle("Notify me before meetings", isOn: Binding(get: { model.remindersEnabled }, set: { enabled in
                    Task {
                        if enabled { await model.beginReminderSetup() }
                        else { await model.setReminders(false) }
                    }
                }))
                .disabled(model.isChangingReminders || model.isPreview)
                if model.reminderAuthorizationStatus == .denied {
                    Text("Notifications are off in macOS. Turn on reminders to review the setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Remind me", selection: $model.reminderMinutes) {
                    Text("1 minute before").tag(1)
                    Text("2 minutes before").tag(2)
                    Text("5 minutes before").tag(5)
                }
                .disabled(!model.remindersEnabled)
                .onChange(of: model.reminderMinutes) { Task { await model.synchronizeReminders() } }
                Text("Reminders open meeting details. Your camera and microphone never turn on automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("On your Mac") {
                Toggle("Open Zooom at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { value in
                    isChangingLogin = true
                    Task {
                        defer { isChangingLogin = false; loginStatus = LaunchAtLoginService.status }
                        do { try await LaunchAtLoginService.setEnabled(value) }
                        catch { model.error = error.localizedDescription }
                    }
                })).disabled(isChangingLogin || loginStatus == .unavailable)
                if loginStatus == .requiresApproval {
                    Button("Allow Zooom in Login Items…") { LaunchAtLoginService.openSystemSettings() }
                    Text("macOS needs your approval before Zooom can open at login.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Zooom also lives in your menu bar. Use ⌘J to paste a meeting link and ⌘Return to join your next meeting.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var development: some View {
        Form {
            Section("Zooom 0.1 · Personal development build") {
                Text("A personal development build. Interface preview uses sample people and messages on this Mac.")
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
            Section("Developer configuration") {
                Button("Replace Google desktop client…") { importGoogle() }.disabled(model.isConnecting)
                Text("Imports the downloaded desktop OAuth client JSON. Credentials and connection tokens are stored in your Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func importGoogle() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Google desktop OAuth client"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importGoogleConfiguration(from: url) }
    }
}
