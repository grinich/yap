import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import YapMeetings
import YapSystem

@MainActor @Observable
public final class ZoomConnectionModel {
    public let client: ZoomAccountClient
    public private(set) var isConfigured = false
    public private(set) var configurationMode: ZoomConfigurationMode = .unconfigured
    public var hasPublicConfiguration: Bool { client.hasPublicConfiguration }
    public private(set) var hasSavedConnection = false
    public private(set) var isConnecting = false
    public private(set) var isUpdatingConfiguration = false
    public private(set) var isLoadingStatus = false
    public private(set) var hasLoadedStatus = false
    public private(set) var statusError: String?
    public var error: String?
    public private(set) var accountRevision = UUID()
    @ObservationIgnored var onAccountWillChange: (() -> Void)?
    // Reading saved status is separate from a mutation. A background refresh
    // must not prevent an already-connected account from joining a meeting.
    public var isBusy: Bool { isConnecting || isUpdatingConfiguration }

    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var statusRequestID = UUID()
    @ObservationIgnored private let openURL: @MainActor @Sendable (URL) -> Void
    @ObservationIgnored private let onSignInCompleted: @MainActor () -> Void

    public init(client: ZoomAccountClient = ZoomAccountClient(),
                openURL: @escaping @MainActor @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
                onSignInCompleted: @escaping @MainActor () -> Void = { YapSystemActions.request(.openYap) }) {
        self.client = client
        self.openURL = openURL
        self.onSignInCompleted = onSignInCompleted
    }

    public func loadStatus() async {
        guard !Task.isCancelled else { return }
        await refreshStatus(for: operationID)
    }

    private func refreshStatus(for expectedOperation: UUID) async {
        let requestID = UUID()
        statusRequestID = requestID
        isLoadingStatus = true
        if error == statusError { error = nil }
        statusError = nil
        defer {
            if operationID == expectedOperation, statusRequestID == requestID {
                isLoadingStatus = false
                if Task.isCancelled, !hasLoadedStatus {
                    statusError = "The connection check was interrupted. Retry to check your saved Zoom account."
                }
            }
        }
        do {
            let mode = try await client.configurationMode()
            guard operationID == expectedOperation, statusRequestID == requestID, !Task.isCancelled else { return }
            let connected = try await client.hasSavedConnection()
            guard operationID == expectedOperation, statusRequestID == requestID, !Task.isCancelled else { return }
            configurationMode = mode
            isConfigured = mode != .unconfigured
            hasSavedConnection = connected
            hasLoadedStatus = true
        } catch is CancellationError {
            if operationID == expectedOperation, statusRequestID == requestID, !hasLoadedStatus {
                statusError = "The connection check was interrupted. Retry to check your saved Zoom account."
            }
        } catch {
            guard operationID == expectedOperation, statusRequestID == requestID, !Task.isCancelled else { return }
            statusError = error.localizedDescription
            self.error = statusError
        }
    }

    public func connect() async {
        guard !isBusy, !Task.isCancelled else { return }
        let currentOperation = beginOperation()
        isConnecting = true
        defer { if operationID == currentOperation { isConnecting = false } }
        do {
            try await client.connect(openURL: openURL)
            guard operationID == currentOperation, !Task.isCancelled else { return }
            await refreshStatus(for: currentOperation)
            guard operationID == currentOperation, !Task.isCancelled else { return }
            onSignInCompleted()
        } catch is CancellationError {
        } catch {
            guard operationID == currentOperation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    public func importConfiguration(from url: URL) async {
        guard !isBusy, !isLoadingStatus, !Task.isCancelled else { return }
        let currentOperation = beginOperation()
        isUpdatingConfiguration = true
        defer { if operationID == currentOperation { isUpdatingConfiguration = false } }
        do {
            // Bound the read before decoding so a mistakenly selected large file
            // cannot block the settings window or load arbitrary data into memory.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_385) ?? Data()
            try await client.configure(fromJSON: data)
            guard operationID == currentOperation else { return }
            await refreshStatus(for: currentOperation)
        } catch is CancellationError {
        } catch {
            guard operationID == currentOperation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Manual setup goes straight to the credential store without a temporary
    /// JSON file. The account client validates field bounds before any mutation.
    @discardableResult
    public func saveConfiguration(_ configuration: ZoomPersonalConfiguration) async -> Bool {
        guard !isBusy, !isLoadingStatus, !Task.isCancelled else { return false }
        let currentOperation = beginOperation()
        isUpdatingConfiguration = true
        defer { if operationID == currentOperation { isUpdatingConfiguration = false } }
        do {
            try await client.configure(configuration)
            guard operationID == currentOperation, !Task.isCancelled else { return false }
            await refreshStatus(for: currentOperation)
            return operationID == currentOperation && error == nil && isConfigured
        } catch is CancellationError {
            return false
        } catch {
            guard operationID == currentOperation, !Task.isCancelled else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    public func disconnect() async {
        guard !isUpdatingConfiguration, !Task.isCancelled else { return }
        let currentOperation = beginOperation()
        isConnecting = false
        isUpdatingConfiguration = true
        defer { if operationID == currentOperation { isUpdatingConfiguration = false } }
        do {
            try await client.disconnect()
            guard operationID == currentOperation else { return }
            await refreshStatus(for: currentOperation)
        } catch is CancellationError {
        } catch {
            guard operationID == currentOperation, !Task.isCancelled else { return }
            let disconnectError = error.localizedDescription
            // Removing the active vault record can succeed before cleanup of
            // an older Keychain item fails. Reconcile the saved connection so
            // the user can sign in again, while still reporting that failure.
            await refreshStatus(for: currentOperation)
            guard operationID == currentOperation, !Task.isCancelled else { return }
            self.error = disconnectError
        }
    }

    public func usePublicConfiguration() async {
        guard hasPublicConfiguration, !isBusy, !isLoadingStatus, !Task.isCancelled else { return }
        let currentOperation = beginOperation()
        isUpdatingConfiguration = true
        defer { if operationID == currentOperation { isUpdatingConfiguration = false } }
        do {
            try await client.usePublicConfiguration()
            guard operationID == currentOperation, !Task.isCancelled else { return }
            await refreshStatus(for: currentOperation)
        } catch is CancellationError {
        } catch {
            guard operationID == currentOperation, !Task.isCancelled else { return }
            let configurationError = error.localizedDescription
            // The active override and tokens may already be removed even when
            // legacy cleanup is denied. Show the saved mode, retaining the error.
            await refreshStatus(for: currentOperation)
            guard operationID == currentOperation, !Task.isCancelled else { return }
            self.error = configurationError
        }
    }

    private func beginOperation() -> UUID {
        // Invalidate account-owned recordings synchronously. A fast mutation may
        // finish between SwiftUI frames, so observing only isBusy can miss it.
        onAccountWillChange?()
        accountRevision = UUID()
        operationID = UUID()
        statusRequestID = UUID()
        isLoadingStatus = false
        statusError = nil
        error = nil
        return operationID
    }
}

struct ZoomConnectionView: View {
    @Bindable var model: YapModel
    @Bindable var connection: ZoomConnectionModel
    @State private var showConfigurationEntry = false

    private var statusLabel: String {
        if connection.hasSavedConnection { return "Account connected" }
        if connection.isLoadingStatus || (!connection.hasLoadedStatus && connection.statusError == nil) { return "Checking connection…" }
        if !connection.hasLoadedStatus { return "Connection status unavailable" }
        return "Not connected"
    }

    var body: some View {
        Section {
            HStack {
                Label("Zoom", systemImage: "video")
                Spacer()
                Text(statusLabel).foregroundStyle(.secondary)
            }
            Text("Use your Zoom account to join and host ordinary Zoom meetings.").font(.callout).foregroundStyle(.secondary)
            if connection.isLoadingStatus || (!connection.hasLoadedStatus && connection.statusError == nil) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking saved Zoom connection…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let statusError = connection.statusError {
                HStack(alignment: .top) {
                    Text(statusError).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await connection.loadStatus() } }
                        .disabled(connection.isLoadingStatus || connection.isBusy)
                        .accessibilityLabel("Retry checking Zoom connection")
                }
            }
            if connection.hasLoadedStatus, connection.isConfigured {
                if connection.isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Zoom…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel sign-in") { Task { await connection.disconnect() } }
                            .disabled(model.activeCall || connection.isUpdatingConfiguration)
                    }
                } else if connection.hasSavedConnection {
                    Button("Disconnect Zoom", role: .destructive) { Task { await connection.disconnect() } }
                        .disabled(model.activeCall || connection.isBusy)
                } else {
                    Button("Sign in to Zoom") { Task { await connection.connect() } }
                        .disabled(connection.isBusy || connection.isLoadingStatus || model.activeCall)
                }
                Menu(connection.hasPublicConfiguration ? "Developer configuration…" : "Replace Zoom configuration…") {
                    Button("Enter Zoom configuration…", action: enterConfiguration)
                    Button("Import Zoom configuration…", action: importConfiguration)
                    if connection.hasPublicConfiguration, connection.configurationMode == .personal {
                        Divider()
                        Button("Use Yap sign-in") { Task { await connection.usePublicConfiguration() } }
                    }
                }
                .disabled(model.activeCall || connection.isBusy || connection.isLoadingStatus)
            } else if connection.hasLoadedStatus, connection.statusError == nil {
                Text("Your personal Zoom connection needs its initial developer setup.").font(.callout)
                Button("Enter Zoom configuration…", action: enterConfiguration).disabled(model.activeCall || connection.isBusy || connection.isLoadingStatus)
                Button("Import Zoom configuration…") { importConfiguration() }.disabled(model.activeCall || connection.isBusy || connection.isLoadingStatus)
                Link("Open Zoom developer setup", destination: URL(string: "https://marketplace.zoom.us/")!)
            }
            if !model.meeting.capabilities.supportsNativeVideo {
                Label("Meeting SDK installation pending", systemImage: "shippingbox")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Your meetings") }
        .task { await connection.loadStatus() }
        .sheet(isPresented: $showConfigurationEntry, onDismiss: { connection.error = nil }) {
            ZoomConfigurationEntry(model: model, connection: connection)
        }
        .alert("Zoom connection", isPresented: Binding(get: { connection.error != nil && connection.statusError == nil && !showConfigurationEntry }, set: { if !$0 { connection.error = nil } })) {
            ZoomSignInButton(error: connection.error ?? "", recovery: model.recordings.zoomSignInRecovery)
            Button("OK", role: .cancel) { connection.error = nil }
        } message: { Text(connection.error ?? "") }
    }

    private func enterConfiguration() {
        guard !model.activeCall, !connection.isBusy, !connection.isLoadingStatus else { return }
        connection.error = nil
        showConfigurationEntry = true
    }

    private func importConfiguration() {
        guard !model.activeCall, !connection.isBusy, !connection.isLoadingStatus else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose your personal Zoom developer configuration"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard !model.activeCall, !connection.isBusy, !connection.isLoadingStatus else { return }
            await connection.importConfiguration(from: url)
        }
    }
}

private struct ZoomConfigurationEntry: View {
    @Bindable var model: YapModel
    @Bindable var connection: ZoomConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var publicClientID = ""
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case clientID, clientSecret, publicClientID }
    private var configuration: ZoomPersonalConfiguration {
        ZoomPersonalConfiguration(sdkClientID: clientID, sdkClientSecret: clientSecret, oauthPublicClientID: publicClientID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(connection.isConfigured ? "Replace Zoom configuration" : "Set up Zoom")
                    .font(.system(size: 23, weight: .semibold))
                Text("Enter the credentials from your personal Zoom developer app. They are saved in this Mac’s Keychain.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    Text("Client ID")
                    TextField("Client ID", text: $clientID)
                        .focused($focusedField, equals: .clientID)
                        .accessibilityLabel("Client ID")
                }
                GridRow {
                    Text("Client Secret")
                    SecureField("Client Secret", text: $clientSecret)
                        .focused($focusedField, equals: .clientSecret)
                        .privacySensitive().accessibilityLabel("Client Secret")
                }
                GridRow {
                    Text("Public OAuth Client ID")
                    TextField("Public OAuth Client ID", text: $publicClientID)
                        .focused($focusedField, equals: .publicClientID)
                        .accessibilityLabel("Public OAuth Client ID")
                }
            }
            .font(.system(size: 13)).textFieldStyle(.roundedBorder)
            .disabled(isSaving || connection.isBusy || connection.isLoadingStatus || model.activeCall)
            if connection.isConfigured {
                Text("Saving replaces the current configuration and disconnects the saved Zoom account. Sign in again after saving.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = connection.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { clearFields(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(isSaving ? "Saving…" : "Save configuration", action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isSaving || connection.isBusy || connection.isLoadingStatus || model.activeCall || !configuration.isValid)
            }
        }
        .padding(28).frame(width: 570)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focusedField = .clientID }
        .onDisappear(perform: clearFields)
        .onChange(of: model.activeCall) { _, active in
            if active { clearFields(); dismiss() }
        }
    }

    private func save() {
        guard !isSaving, !connection.isBusy, !connection.isLoadingStatus, !model.activeCall else { return }
        let value = configuration
        guard value.isValid else { return }
        // Clear the secure field as soon as the user commits; pass the value
        // directly to the Keychain-backed operation without a plaintext file.
        clientSecret = ""
        isSaving = true
        Task {
            guard !model.activeCall, !connection.isBusy, !connection.isLoadingStatus else { isSaving = false; return }
            let saved = await connection.saveConfiguration(value)
            isSaving = false
            if saved { clearFields(); dismiss() }
            else { focusedField = .clientSecret }
        }
    }

    private func clearFields() {
        clientSecret = ""
        clientID = ""
        publicClientID = ""
    }
}
