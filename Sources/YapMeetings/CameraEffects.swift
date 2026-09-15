import AppKit
import Foundation

public enum CameraBackgroundChoice: Codable, Equatable, Sendable {
    case none
    case blur
    case image(path: String)
}

public struct CameraEffectsPreferences: Codable, Equatable, Sendable {
    public var background: CameraBackgroundChoice
    public var autoFraming: Bool

    public init(background: CameraBackgroundChoice = .none, autoFraming: Bool = false) {
        self.background = background
        self.autoFraming = autoFraming
    }
}

public struct CameraEffectsStatus: Equatable, Sendable {
    public var supportsBlur: Bool
    public var supportsImageBackgrounds: Bool
    public var canAddImages: Bool
    public var isInMeeting: Bool
    public var isCameraOn: Bool
    public var isPreviewing: Bool
    public var appliedPreferences: CameraEffectsPreferences?
    public var previewError: String?

    public init(supportsBlur: Bool = false, supportsImageBackgrounds: Bool = false,
                canAddImages: Bool = false, isInMeeting: Bool = false,
                isCameraOn: Bool = false, isPreviewing: Bool = false,
                appliedPreferences: CameraEffectsPreferences? = nil, previewError: String? = nil) {
        self.supportsBlur = supportsBlur
        self.supportsImageBackgrounds = supportsImageBackgrounds
        self.canAddImages = canAddImages
        self.isInMeeting = isInMeeting
        self.isCameraOn = isCameraOn
        self.isPreviewing = isPreviewing
        self.appliedPreferences = appliedPreferences
        self.previewError = previewError
    }
}

/// A settings/preview session must never join a meeting or unmute the sending camera.
/// The live driver coordinates this with the Meeting SDK's single process-wide instance.
@MainActor
public protocol CameraEffectsDriver: AnyObject {
    var onCameraEffectsChanged: (@MainActor (CameraEffectsStatus) -> Void)? { get set }
    func setPreferredCameraEffects(_ preferences: CameraEffectsPreferences)
    func prepareCameraEffects() async throws -> CameraEffectsStatus
    func applyCameraEffects(_ preferences: CameraEffectsPreferences) async throws -> CameraEffectsStatus
    func startCameraEffectsPreview() async throws -> NSView
    func stopCameraEffectsPreview()
    /// Close only the settings session; an active meeting must continue untouched.
    func closeCameraEffects()
}
