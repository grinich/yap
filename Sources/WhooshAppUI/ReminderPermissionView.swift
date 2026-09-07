import SwiftUI

/// Whoosh explains the choice here. macOS retains its own permission controls.
struct ReminderPermissionView: View {
    @Bindable var model: WhooshModel

    private var isDenied: Bool { model.reminderAuthorizationStatus == .denied }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 64, height: 64)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(isDenied ? "Turn on meeting reminders" : "Ready for your next meeting")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            if model.isChangingReminders {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Choose Allow in the macOS notification request.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if model.isWaitingForNotificationSettings {
                Text("Zooom will check again when you return.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let error = model.reminderPermissionError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Not now", role: .cancel) { model.cancelReminderSetup() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(isDenied ? "Open Notification Settings" : "Enable notifications") {
                    if isDenied { model.openReminderNotificationSettings() }
                    else { Task { await model.setReminders(true) } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingReminders)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
    }

    private var explanation: String {
        if isDenied {
            "Notifications are off for Zooom. In System Settings, select Zooom and turn on Allow Notifications."
        } else {
            "Get a reminder before your Zoom meetings, with a shortcut back to Zooom. macOS will ask you to allow notifications."
        }
    }
}
