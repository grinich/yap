import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YapMeetings

struct CameraEffectsSettingsView: View {
    @Bindable var effects: CameraEffectsModel
    @Bindable var connection: ZoomConnectionModel
    var isDemo = false
    @State private var choosePhoto = false

    private enum BackgroundMode: Hashable { case none, blur, photo }
    private var mode: BackgroundMode {
        switch effects.selection.background {
        case .none: .none
        case .blur: .blur
        case .image: .photo
        }
    }
    private var canChange: Bool { !isDemo && effects.status != nil && !effects.isBusy && !connection.isConnecting }

    var body: some View {
        Form {
            if effects.isLoading || effects.isApplying {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(effects.isLoading ? "Loading camera settings…" : "Applying camera effect…")
                        .foregroundStyle(.secondary)
                }
            }
            if isDemo {
                Text("Camera effects are available in live mode. Interface preview doesn’t turn on your camera.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let error = effects.error {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Try again") { Task { await effects.prepare() } }.disabled(effects.isBusy)
                        if effects.status != nil, effects.selection != CameraEffectsPreferences() {
                            Button("Reset effects") { Task { await effects.resetEffects() } }.disabled(effects.isBusy)
                        }
                        if ZoomSignInError.matches(error) {
                            Button(connection.isConnecting ? "Signing in…" : "Sign in to Zoom") {
                                Task {
                                    await connection.connect()
                                    await effects.prepare()
                                }
                            }.disabled(connection.isConnecting)
                        }
                    }
                }
            }
            Section {
                preview
                HStack {
                    Text(effects.status?.isInMeeting == true
                         ? "Use your meeting self-view to check camera effects."
                         : "Preview locally before your next meeting.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if effects.preview != nil {
                        Button("Stop preview") { effects.stopPreview() }
                            .accessibilityIdentifier("cameraEffectsStopPreview")
                    }
                }
            }
            Section("Background") {
                Picker("Background", selection: Binding(get: { mode }, set: { selectBackground($0) })) {
                    Text("None").tag(BackgroundMode.none)
                    Text("Blur").tag(BackgroundMode.blur).disabled(effects.status?.supportsBlur != true)
                    Text("Photo").tag(BackgroundMode.photo).disabled(effects.status?.supportsImageBackgrounds != true || (effects.status?.canAddImages != true && effects.backgroundImageURL == nil))
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!canChange)
                .accessibilityIdentifier("cameraBackgroundPicker")
                HStack(spacing: 12) {
                    if let url = effects.backgroundImageURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Your saved background photo")
                        Text("Custom photo").font(.callout)
                    } else {
                        Text("Use a photo from your Mac.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(effects.backgroundImageURL == nil ? "Choose photo…" : "Change photo…") { choosePhoto = true }
                        .disabled(!canChange || effects.status?.supportsImageBackgrounds != true || effects.status?.canAddImages != true)
                        .accessibilityIdentifier("cameraChooseBackgroundPhoto")
                }
                if let status = effects.status, !status.supportsBlur || !status.supportsImageBackgrounds {
                    Text("Some backgrounds aren’t available for this camera, computer, or meeting’s settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Framing") {
                Toggle(isOn: Binding(get: { effects.selection.autoFraming }, set: { enabled in
                    Task { await effects.setAutoFraming(enabled) }
                })) {
                    SettingsLabel(title: "Automatically frame me", detail: "Keep your face centered as you move.")
                }
                .toggleStyle(.switch).disabled(!canChange)
                .accessibilityIdentifier("cameraAutoFraming")
            }

        }
        .formStyle(.grouped)
        .task { if !isDemo { await effects.prepare() } }
        .onDisappear { effects.close() }
        .fileImporter(isPresented: $choosePhoto, allowedContentTypes: [.png, .jpeg, .heic, .tiff]) { result in
            if case .success(let url) = result { Task { await effects.importPhoto(from: url) } }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.9))
            if let view = effects.preview {
                NativeRendererContainer(renderer: view)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.rectangle").font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                    if effects.status?.isInMeeting == true {
                        Text("Preview in your meeting")
                            .font(.callout).foregroundStyle(.white.opacity(0.8))
                    } else if effects.isStartingPreview {
                        ProgressView("Starting camera…").controlSize(.small)
                            .foregroundStyle(.white)
                    } else {
                        Button("Preview camera") { Task { await effects.startPreview() } }
                            .buttonStyle(.borderedProminent).disabled(!canChange)
                            .accessibilityIdentifier("cameraEffectsStartPreview")
                    }
                }
            }
        }
        .frame(height: 190)
    }

    private func selectBackground(_ mode: BackgroundMode) {
        switch mode {
        case .none: Task { await effects.setBackground(.none) }
        case .blur: Task { await effects.setBackground(.blur) }
        case .photo:
            if let url = effects.backgroundImageURL { Task { await effects.setBackground(.image(path: url.path)) } }
            else { choosePhoto = true }
        }
    }
}
