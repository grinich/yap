import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import YapMeetings

@MainActor @Observable
public final class CameraEffectsModel {
    public private(set) var selection: CameraEffectsPreferences
    public private(set) var status: CameraEffectsStatus?
    public private(set) var isLoading = false
    public private(set) var isApplying = false
    public private(set) var isStartingPreview = false
    public private(set) var preview: NSView?
    public private(set) var error: String?
    public private(set) var backgroundImageURL: URL?
    public var isAvailable: Bool { driver != nil }
    public var isBusy: Bool { isLoading || isApplying || isStartingPreview }

    @ObservationIgnored private let driver: (any CameraEffectsDriver)?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isOpen = false
    private static let preferenceKey = "camera.effects.v1"
    private static let photoKey = "camera.backgroundPhotoPath.v1"

    public init(driver: (any CameraEffectsDriver)?, preferences: UserDefaults = .standard, directory: URL? = nil) {
        self.driver = driver
        self.preferences = preferences
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Yap/Camera Backgrounds", directoryHint: .isDirectory)
        selection = preferences.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(CameraEffectsPreferences.self, from: $0) } ?? CameraEffectsPreferences()
        if case .image(let path) = selection.background {
            backgroundImageURL = URL(fileURLWithPath: path)
        } else if let path = preferences.string(forKey: Self.photoKey) {
            backgroundImageURL = URL(fileURLWithPath: path)
        }
        driver?.setPreferredCameraEffects(selection)
        driver?.onCameraEffectsChanged = { [weak self] status in
            guard let self, self.isOpen else { return }
            self.status = status
            if !status.isPreviewing { self.preview = nil }
            if let error = status.previewError {
                self.error = error
            }
        }
    }

    public func prepare() async {
        guard !isBusy else { return }
        isOpen = true
        let token = generation
        guard let driver else {
            error = "Camera effects aren’t available in this preview. Open a build with Zoom connected to use them."
            return
        }
        isLoading = true
        error = nil
        defer { if token == generation { isLoading = false } }
        do {
            let result = try await driver.prepareCameraEffects()
            try Task.checkCancellation()
            guard token == generation else { return }
            status = result
        } catch {
            guard token == generation, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    public func setBackground(_ choice: CameraBackgroundChoice) async {
        var next = selection
        next.background = choice
        _ = await apply(next)
    }

    public func setAutoFraming(_ enabled: Bool) async {
        var next = selection
        next.autoFraming = enabled
        _ = await apply(next)
    }

    public func resetEffects() async {
        _ = await apply(CameraEffectsPreferences())
    }

    @discardableResult private func apply(_ next: CameraEffectsPreferences) async -> Bool {
        guard !isBusy, let driver else { return false }
        isOpen = true
        let token = generation
        isApplying = true
        error = nil
        defer { if token == generation { isApplying = false } }
        do {
            let result = try await driver.applyCameraEffects(next)
            try Task.checkCancellation()
            guard token == generation else { return false }
            // The backend verifies the selected SDK background and framing state.
            guard result.appliedPreferences == next else {
                throw CameraEffectsModelError.notConfirmed
            }
            selection = next
            status = result
            driver.setPreferredCameraEffects(next)
            preferences.set(try JSONEncoder().encode(next), forKey: Self.preferenceKey)
            if case .image(let path) = next.background {
                backgroundImageURL = URL(fileURLWithPath: path)
                preferences.set(path, forKey: Self.photoKey)
            }
            return true
        } catch {
            guard token == generation, !(error is CancellationError) else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    public func importPhoto(from url: URL) async {
        guard !isBusy else { return }
        error = nil
        var imported: URL?
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 32 * 1024 * 1024 else {
                throw CameraEffectsModelError.invalidImage
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3840,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw CameraEffectsModelError.invalidImage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: "\(UUID().uuidString).png")
            imported = target
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CameraEffectsModelError.cannotSaveImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CameraEffectsModelError.cannotSaveImage }
            var next = selection
            next.background = .image(path: target.path)
            if await apply(next) { imported = nil }
        } catch {
            self.error = error.localizedDescription
        }
        // Delete only this attempt's newly generated file, never the user's original.
        if let imported { try? FileManager.default.removeItem(at: imported) }
    }

    public func startPreview() async {
        guard !isBusy, preview == nil, let driver else { return }
        isOpen = true
        let token = generation
        isStartingPreview = true
        error = nil
        defer { if token == generation { isStartingPreview = false } }
        do {
            let view = try await driver.startCameraEffectsPreview()
            try Task.checkCancellation()
            guard token == generation else { return }
            preview = view
        } catch {
            guard token == generation, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    public func stopPreview() {
        driver?.stopCameraEffectsPreview()
        preview = nil
    }

    public func close() {
        generation = UUID()
        isOpen = false
        driver?.closeCameraEffects()
        preview = nil
        status = nil
        isLoading = false
        isApplying = false
        isStartingPreview = false
    }
}

private enum CameraEffectsModelError: LocalizedError {
    case invalidImage, cannotSaveImage, notConfirmed
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Choose a readable photo smaller than 32 MB."
        case .cannotSaveImage: "Yap couldn’t save this background. Try another photo."
        case .notConfirmed: "Zoom hasn’t confirmed this camera effect. Your saved choice hasn’t changed. Try again."
        }
    }
}
