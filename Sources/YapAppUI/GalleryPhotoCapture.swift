import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import YapMeetings

@MainActor @Observable
final class GalleryPhotoCapture {
    var countdown: Int?
    var isBusy = false
    var progressText: String?
    var isCapturingFrame = false
    var image: NSImage?
    var savedURL: URL?
    var saveError: String?
    var error: String?
    var needsScreenRecordingPermission = false
    var soundNotice: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var localSound: NSSound?
    @ObservationIgnored private let windowCapture: GalleryPhotoWindowCapture

    @ObservationIgnored private let downloadsDirectory: () throws -> URL

    init(windowCapture: GalleryPhotoWindowCapture = .live,
         downloadsDirectory: @escaping () throws -> URL = {
             try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
         }) {
        self.windowCapture = windowCapture
        self.downloadsDirectory = downloadsDirectory
    }

    func start(meeting: MeetingCoordinator, window: NSWindow?) {
        guard !isBusy, let window, let session = meeting.sessionID,
              meeting.isConnected, !meeting.photoParticipants.isEmpty else { return }
        isBusy = true
        image = nil; savedURL = nil; saveError = nil
        error = nil; soundNotice = nil; needsScreenRecordingPermission = false
        progressText = "Preparing group photo…"
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.countdown = nil
                self.progressText = nil
                self.isCapturingFrame = false
                meeting.endGroupPhoto(sessionID: session)
                if meeting.sessionID == session { meeting.cancelPhotoShutter() }
                self.isBusy = false
                self.task = nil
            }
            do {
                // Establish screen access before changing subscriptions or starting the countdown.
                let captureWindow = try await self.windowCapture.prepare(window)
                try Task.checkCancellation()
                let people = try meeting.beginGroupPhoto(sessionID: session)
                let pcm = Self.shutterPCM()
                let crops: [CGImage] = try await GalleryPhotoBatchCapture.collect(participantIDs: people.map(\.id)) { ids, index, total in
                    self.progressText = total > 1 ? "Preparing cameras · Group \(index + 1) of \(total)" : "Preparing cameras…"
                    try meeting.selectGroupPhotoBatch(participantIDs: ids, sessionID: session)
                    try await self.waitForCameras(ids, meeting: meeting, window: window, session: session)
                    if index == 0 {
                        do { try await meeting.preparePhotoShutter(pcm) }
                        catch { self.soundNotice = "Zoom didn’t allow the shutter sound to be shared. It played on this Mac only." }
                        self.progressText = total > 1 ? "Keep smiling — capturing \(total) groups" : nil
                        for number in [3, 2, 1] {
                            try Task.checkCancellation()
                            try meeting.validateGroupPhotoBatch(sessionID: session)
                            self.countdown = number
                            try await Task.sleep(for: .seconds(1))
                        }
                        self.countdown = nil
                    }
                } capture: { ids, index, total in
                    self.progressText = "Capturing group \(index + 1) of \(total)…"
                    self.isCapturingFrame = true
                    defer { self.isCapturingFrame = false }
                    // Let the countdown/cancel controls leave the compositor before reading GPU surfaces.
                    try await Task.sleep(for: .milliseconds(250))
                    try meeting.validateGroupPhotoBatch(sessionID: session)
                    let frames = try self.cameraFrames(ids, meeting: meeting, window: window)
                    let scale = window.backingScaleFactor
                    let size = window.frame.size
                    if index == 0 {
                        if !meeting.playPhotoShutter() {
                            self.soundNotice = "Zoom didn’t allow the shutter sound to be shared. It played on this Mac only."
                        }
                        self.localSound = NSSound(data: Self.wave(pcm))
                        self.localSound?.play()
                    }
                    let screenshot = try await captureWindow(size, scale)
                    try Task.checkCancellation()
                    try meeting.validateGroupPhotoBatch(sessionID: session)
                    guard window.frame.size == size, window.backingScaleFactor == scale,
                          try self.cameraFrames(ids, meeting: meeting, window: window) == frames else {
                        throw PhotoError.message("The call window changed during the photo. Keep it in place and try again.")
                    }
                    return try frames.map { rect -> CGImage in
                        let pixels = CGRect(x: rect.minX * scale,
                                            y: CGFloat(screenshot.height) - rect.maxY * scale,
                                            width: rect.width * scale, height: rect.height * scale).integral
                        guard CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height).contains(pixels),
                              let crop = screenshot.cropping(to: pixels) else {
                            throw PhotoError.message("Keep the full call window visible and try again.")
                        }
                        return crop
                    }
                } release: {
                    meeting.clearGroupPhotoBatch(sessionID: session)
                }
                try Task.checkCancellation()
                guard meeting.sessionID == session, meeting.isConnected else { throw CancellationError() }
                let completedImage = try Self.collage(crops)
                // Let the brief PCM effect finish before cleaning up its share channel.
                try await Task.sleep(for: .milliseconds(450))
                try Task.checkCancellation()
                guard meeting.sessionID == session, meeting.isConnected else { throw CancellationError() }
                self.image = completedImage
                self.saveToDownloads()
            } catch is CancellationError { self.image = nil }
            catch {
                self.image = nil
                if case PhotoError.screenRecordingPermission = error { self.needsScreenRecordingPermission = true }
                self.error = error.localizedDescription
            }
        }
    }

    private func waitForCameras(_ ids: [String], meeting: MeetingCoordinator, window: NSWindow, session: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            try Task.checkCancellation()
            try meeting.validateGroupPhotoBatch(sessionID: session)
            if (try? cameraFrames(ids, meeting: meeting, window: window)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PhotoError.message("Some camera feeds didn’t become ready in time. No partial photo was saved. Try again in a moment.")
    }

    private func cameraFrames(_ ids: [String], meeting: MeetingCoordinator, window: NSWindow) throws -> [CGRect] {
        try ids.map { id in
            guard meeting.isVideoReadyForCapture(for: id),
                  let view = meeting.nativeVideoView(for: id), view.window === window,
                  view.bounds.width > 1, view.bounds.height > 1 else {
                throw PhotoError.message("Some camera feeds aren’t ready yet. Try the photo again in a moment.")
            }
            let screen = window.convertToScreen(view.convert(view.bounds, to: nil))
            return screen.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        }
    }

    func cancel() { task?.cancel() }

    func saveToDownloads() {
        guard savedURL == nil, let image else { return }
        do {
            savedURL = try Self.writePhoto(image, to: downloadsDirectory())
            saveError = nil
        } catch {
            // Keep the captured image available so retrying never requires another photo.
            saveError = "Couldn’t save to Downloads: \(error.localizedDescription)"
        }
    }

    static func writePhoto(_ image: NSImage, to directory: URL, now: Date = .now) throws -> URL {
        guard let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw PhotoError.message("The photo couldn’t be converted to a PNG.")
        }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Yap group photo \(formatter.string(from: now))"
        // Stage the complete PNG on the same volume. Moving it into place never
        // replaces an existing photo, including a concurrent save at the same time.
        let staging = directory.appendingPathComponent(".yap-photo-\(UUID().uuidString).png")
        defer { try? files.removeItem(at: staging) }
        try png.write(to: staging, options: .atomic)
        var suffix = 1
        while true {
            let name = suffix == 1 ? stem : "\(stem) (\(suffix))"
            let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
            do {
                try files.moveItem(at: staging, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    static func collage(_ images: [CGImage]) throws -> NSImage {
        guard !images.isEmpty else { throw PhotoError.message("No camera images were available.") }
        let columns = max(1, Int(ceil(sqrt(Double(images.count)))))
        let rows = (images.count + columns - 1) / columns
        // Preserve source detail without enlarging tiny feeds or creating unbounded files.
        let tileWidth = min(640, max(1, images.map(\.width).min() ?? 320))
        let tileHeight = max(1, tileWidth * 9 / 16)
        let width = columns * tileWidth, height = rows * tileHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PhotoError.message("Couldn’t create the photo.")
        }
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let row = index / columns, column = index % columns
            let count = min(columns, images.count - row * columns)
            let rect = CGRect(x: (width - count * tileWidth) / 2 + column * tileWidth,
                              y: height - (row + 1) * tileHeight, width: tileWidth, height: tileHeight)
            let factor = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
            context.saveGState(); context.clip(to: rect)
            context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw PhotoError.message("Couldn’t create the photo.") }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }

    static func shutterPCM() -> Data {
        var state: UInt32 = 42
        let samples: [Int16] = (0..<13230).map { index in
            state = 1664525 &* state &+ 1013904223
            let t = Double(index) / 44100
            let noise = Double(state & 65535) / 32767.5 - 1
            let envelope = exp(-t * 65) + (t > 0.095 ? 0.75 * exp(-(t - 0.095) * 85) : 0)
            return Int16(max(-32767, min(32767, noise * envelope * 13000)))
        }
        return samples.withUnsafeBytes { Data($0) }
    }
    static func wave(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) { var n = number.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(44100))
        append(UInt32(88200)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    enum PhotoError: LocalizedError {
        case message(String)
        case screenRecordingPermission
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .screenRecordingPermission:
                return "Allow Screen Recording for Yap in System Settings to take a group photo, then try again."
            }
        }
    }
}

/// Keeps OS permission/capture at the boundary so fixtures can exercise the same
/// countdown, live-view layout, batching, and collage with local synthetic feeds.
@MainActor
struct GalleryPhotoWindowCapture {
    typealias Capture = @MainActor (CGSize, CGFloat) async throws -> CGImage
    var prepare: @MainActor (NSWindow) async throws -> Capture

    static let live = GalleryPhotoWindowCapture { window in
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw GalleryPhotoCapture.PhotoError.screenRecordingPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let captureWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw GalleryPhotoCapture.PhotoError.message("Bring your call window back on screen and try again.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
        return { size, scale in
            let config = SCStreamConfiguration()
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }
}

/// Retains captured stills while only one bounded batch of live feeds is loaded.
@MainActor
enum GalleryPhotoBatchCapture {
    static func collect<Frame>(participantIDs: [String],
                               prepare: ([String], Int, Int) async throws -> Void,
                               capture: ([String], Int, Int) async throws -> [Frame],
                               release: () -> Void) async throws -> [Frame] {
        let limit = MeetingCoordinator.groupPhotoBatchSize
        let total = (participantIDs.count + limit - 1) / limit
        var frames: [Frame] = []
        for (index, start) in stride(from: 0, to: participantIDs.count, by: limit).enumerated() {
            let ids = Array(participantIDs[start..<min(start + limit, participantIDs.count)])
            // Even a partially prepared or failed batch must release its subscriptions.
            defer { release() }
            try Task.checkCancellation()
            try await prepare(ids, index, total)
            try Task.checkCancellation()
            let captured = try await capture(ids, index, total)
            try Task.checkCancellation()
            guard captured.count == ids.count else {
                throw GalleryPhotoCapture.PhotoError.message("Some camera feeds were missing from the photo. Try again to include everyone.")
            }
            frames.append(contentsOf: captured)
        }
        return frames
    }
}

struct GalleryPhotoPreview: View {
    @Bindable var photo: GalleryPhotoCapture
    var body: some View {
        VStack(spacing: 16) {
            Text(photo.savedURL == nil ? "Your group photo" : "Saved to Downloads").font(.title2.bold())
            if let image = photo.image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 850, maxHeight: 550)
            }
            if let error = photo.saveError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = photo.soundNotice { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if let url = photo.savedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Spacer()
                    Button("Done") { photo.image = nil }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Discard photo") { photo.image = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Try again") { photo.saveToDownloads() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(minWidth: 520)
    }
}
