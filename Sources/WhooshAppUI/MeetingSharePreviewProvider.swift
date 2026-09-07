import AppKit
import Observation
import ScreenCaptureKit
import WhooshMeetings

/// These small images live only in the open share chooser. They are never
/// written to disk or passed to Zoom; Zoom captures the confirmed source itself.
@MainActor
struct MeetingSharePreview {
    let image: NSImage?
    let applicationName: String?
    let applicationIcon: NSImage?
}

@MainActor
struct MeetingSharePreviewSource {
    let pickerID: String
    let applicationName: String?
    let applicationIcon: NSImage?
    let capture: @MainActor () async throws -> NSImage
}

@MainActor @Observable
final class MeetingSharePreviewProvider {
    private(set) var previews: [String: MeetingSharePreview] = [:]
    private(set) var isLoading = false

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let loadSources: @MainActor ([ShareTarget]) async throws -> [MeetingSharePreviewSource]
    @ObservationIgnored private let maximumImageCount: Int
    @ObservationIgnored private(set) var loadingTask: Task<Void, Never>?

    init(maximumImageCount: Int = 48,
         loadSources: @escaping @MainActor ([ShareTarget]) async throws -> [MeetingSharePreviewSource] = {
             try await NativeMeetingSharePreviews.sources(for: $0)
         }) {
        self.maximumImageCount = max(0, min(maximumImageCount, 48))
        self.loadSources = loadSources
    }

    /// Call only after live sharing sources have been enumerated for this sheet.
    /// A refresh waits for any previous screenshot to finish before starting the
    /// next one: ScreenCaptureKit's one-shot API has no cancellation operation.
    func start(targets: [ShareTarget]) {
        let previous = loadingTask
        previous?.cancel()
        let request = UUID()
        generation = request
        previews.removeAll()
        var seen: Set<String> = []
        let targets = targets.filter {
            $0.kind != .demo && UInt32($0.id).map { $0 > 0 } == true && seen.insert($0.pickerID).inserted
        }
        isLoading = !targets.isEmpty
        loadingTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == request, !targets.isEmpty else { return }
            defer { if self.generation == request { self.isLoading = false } }
            do {
                let sources = try await self.loadSources(targets)
                guard !Task.isCancelled, self.generation == request else { return }
                let allowedIDs = Set(targets.map(\.pickerID))
                var visited: Set<String> = []
                var imageCount = 0
                for source in sources where allowedIDs.contains(source.pickerID) && visited.insert(source.pickerID).inserted {
                    guard !Task.isCancelled, self.generation == request else { return }
                    self.previews[source.pickerID] = MeetingSharePreview(image: nil,
                        applicationName: source.applicationName, applicationIcon: source.applicationIcon)
                    guard imageCount < self.maximumImageCount else { continue }
                    imageCount += 1
                    // A window can close or become protected between enumeration
                    // and capture. Keep its descriptive fallback without inventing
                    // an image or interrupting the other available previews.
                    let image = try? await MeetingSharePreviewCaptureQueue.shared.capture(source)
                    guard !Task.isCancelled, self.generation == request else { return }
                    self.previews[source.pickerID] = MeetingSharePreview(image: image,
                        applicationName: source.applicationName, applicationIcon: source.applicationIcon)
                }
            } catch {
                // The sharing-source loader owns permission/error presentation.
                // A preview failure leaves source selection and sharing usable.
            }
        }
    }

    /// Invalidates late capture completions and immediately releases all images.
    func clear() {
        generation = UUID()
        loadingTask?.cancel()
        previews.removeAll()
        isLoading = false
    }
}

/// Serializes the actual one-shot captures across chooser instances as well as
/// refreshes. Rapidly closing and reopening a sheet cannot accumulate active
/// ScreenCaptureKit requests. Cancelled queued work acquires and releases its
/// turn without capturing, and this queue never retains any image results.
@MainActor
private final class MeetingSharePreviewCaptureQueue {
    static let shared = MeetingSharePreviewCaptureQueue()
    private var isCapturing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func capture(_ source: MeetingSharePreviewSource) async throws -> NSImage {
        if isCapturing { await withCheckedContinuation { waiting.append($0) } }
        else { isCapturing = true }
        defer {
            if waiting.isEmpty { isCapturing = false }
            else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await source.capture()
    }
}

@MainActor
private enum NativeMeetingSharePreviews {
    static func sources(for targets: [ShareTarget]) async throws -> [MeetingSharePreviewSource] {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        var sources: [MeetingSharePreviewSource] = []
        for target in targets {
            guard let identifier = UInt32(target.id) else { continue }
            let filter: SCContentFilter
            let bounds: CGRect
            let application: SCRunningApplication?
            switch target.kind {
            case .window:
                guard let window = content.windows.first(where: { $0.windowID == identifier }),
                      window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                      window.frame.width > 1, window.frame.height > 1 else { continue }
                filter = SCContentFilter(desktopIndependentWindow: window)
                bounds = window.frame
                application = window.owningApplication
            case .display:
                guard let display = content.displays.first(where: { $0.displayID == identifier }) else { continue }
                filter = SCContentFilter(display: display, excludingWindows: [])
                bounds = display.frame
                application = nil
            case .demo:
                continue
            }
            let applicationIcon = application.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
            sources.append(MeetingSharePreviewSource(pickerID: target.pickerID,
                applicationName: application?.applicationName, applicationIcon: applicationIcon) {
                    try Task.checkCancellation()
                    let configuration = SCStreamConfiguration()
                    let scale = min(384 / max(1, bounds.width), 240 / max(1, bounds.height), 1)
                    configuration.width = max(1, Int((bounds.width * scale).rounded()))
                    configuration.height = max(1, Int((bounds.height * scale).rounded()))
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.captureMicrophone = false
                    configuration.ignoreShadowsSingleWindow = true
                    configuration.scalesToFit = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                })
        }
        return sources
    }
}
