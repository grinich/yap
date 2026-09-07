import AppKit
import SwiftUI
import WhooshSystem

struct LaunchAtLoginSettingsView: View {
    @State private var service = LaunchAtLoginService()

    var body: some View {
        Section("On your Mac") {
            Toggle("Open Zooom at login", isOn: Binding(
                get: { service.isEnabled },
                set: { enabled in Task { await service.setEnabled(enabled) } }
            ))
            .disabled(service.isChanging)
            .accessibilityIdentifier("launchAtLoginToggle")
            if service.isChanging {
                ProgressView("Updating your Mac’s setting…").controlSize(.small)
            }
            if service.status == .requiresApproval {
                Text("macOS needs your approval before Zooom can open at login.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow Zooom in Login Items…") { service.openSystemSettings() }
            }
            if let errorMessage = service.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                if service.status != .requiresApproval {
                    Button("Open Login Items…") { service.openSystemSettings() }
                }
            }
            Text("Zooom also lives in your menu bar. Use ⌘J to paste a meeting link and ⌘Return to join your next meeting.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task { service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refresh()
        }
    }
}
