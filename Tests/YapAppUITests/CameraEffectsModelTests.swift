import AppKit
import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Camera effects settings") @MainActor
struct CameraEffectsModelTests {
    @Test func restoresSavedPreferencesWithoutStartingTheCamera() throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let saved = CameraEffectsPreferences(background: .blur, autoFraming: true)
        try fixture.save(saved)
        let driver = CameraEffectsProbe()

        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }

        #expect(model.selection == saved)
        #expect(driver.preferred == saved)
        #expect(driver.prepareCalls == 0)
        #expect(driver.previewStarts == 0)
        #expect(model.preview == nil)
    }

    @Test func preparingCapabilitiesDoesNotStartAPreview() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }

        await model.prepare()

        #expect(model.status?.supportsBlur == true)
        #expect(model.status?.supportsImageBackgrounds == true)
        #expect(model.status?.isCameraOn == false)
        #expect(model.error == nil)
        #expect(!model.isLoading)
        #expect(driver.prepareCalls == 1)
        #expect(driver.previewStarts == 0)
        #expect(model.preview == nil)
    }

    @Test func successfulChangesPersistTogetherAndRestoreOnReopen() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        await model.prepare()

        await model.setBackground(.blur)
        await model.setAutoFraming(true)

        let expected = CameraEffectsPreferences(background: .blur, autoFraming: true)
        #expect(model.selection == expected)
        #expect(try fixture.saved() == expected)
        #expect(driver.applied.last == expected)
        #expect(model.error == nil)
        #expect(!model.isApplying)
        model.close()

        let reopenedDriver = CameraEffectsProbe()
        let reopened = CameraEffectsModel(driver: reopenedDriver, preferences: fixture.defaults, directory: fixture.images)
        defer { reopened.close() }
        #expect(reopened.selection == expected)
        #expect(reopenedDriver.preferred == expected)
    }

    @Test func failedChangeKeepsTheLastSuccessfulSelectionAndSavedPreferences() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences(background: .blur)
        try fixture.save(original)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        driver.applyError = CameraEffectsFixtureError.rejected

        await model.setAutoFraming(true)

        #expect(driver.applied.last == CameraEffectsPreferences(background: .blur, autoFraming: true))
        #expect(model.selection == original)
        #expect(try fixture.saved() == original)
        #expect(model.error?.contains("rejected") == true)
        #expect(!model.isApplying)
    }

    @Test func closingDuringApplyDiscardsTheLateResultAndDoesNotPersistIt() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences(background: .blur)
        try fixture.save(original)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        await model.prepare()
        driver.pauseApply = true
        let operation = Task { await model.setAutoFraming(true) }
        try await waitUntil { driver.pendingApply != nil }
        #expect(model.isApplying)

        model.close()
        driver.finishApply()
        await operation.value

        #expect(driver.closeCalls == 1)
        #expect(model.selection == original)
        #expect(try fixture.saved() == original)
        #expect(!model.isApplying)
        #expect(model.preview == nil)
        #expect(model.error == nil)
    }

    @Test func anUnconfirmedDriverResponseDoesNotSaveTheRequestedEffect() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences(background: .blur)
        try fixture.save(original)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        driver.confirmsApply = false

        await model.setAutoFraming(true)

        #expect(model.selection == original)
        #expect(try fixture.saved() == original)
        #expect(driver.preferred == original)
        #expect(model.error != nil)
    }

    @Test func resetAfterAnApplyFailurePersistsNoneAndFramingOff() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences(background: .blur, autoFraming: true)
        try fixture.save(original)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        driver.applyError = CameraEffectsFixtureError.rejected
        await model.setAutoFraming(false)
        #expect(model.error != nil)
        #expect(model.status != nil)
        #expect(model.selection == original)

        driver.applyError = nil
        await model.resetEffects()

        let reset = CameraEffectsPreferences()
        #expect(model.selection == reset)
        #expect(try fixture.saved() == reset)
        #expect(driver.preferred == reset)
        #expect(driver.applied.last == reset)
        #expect(model.status?.appliedPreferences == reset)
        #expect(model.error == nil)
    }

    @Test func importsAnOwnedPhotoThatSurvivesRemovalOfTheOriginal() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let originalURL = fixture.root.appendingPathComponent("chosen-photo.png")
        try fixture.writeImage(to: originalURL)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()

        await model.importPhoto(from: originalURL)

        let ownedURL = try #require(model.backgroundImageURL)
        #expect(ownedURL != originalURL)
        #expect(ownedURL.path.hasPrefix(fixture.images.path + "/"))
        #expect(ownedURL.pathExtension.lowercased() == "png")
        #expect(model.selection.background == .image(path: ownedURL.path))
        #expect(driver.applied.last?.background == .image(path: ownedURL.path))
        #expect(try fixture.saved() == model.selection)
        try FileManager.default.removeItem(at: originalURL)
        #expect(NSImage(contentsOf: ownedURL) != nil)
        #expect(model.error == nil)
    }

    @Test func failedPhotoReplacementKeepsTheExistingPhotoAndRemovesOnlyTheNewImport() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let firstURL = fixture.root.appendingPathComponent("first.png")
        let secondURL = fixture.root.appendingPathComponent("second.png")
        try fixture.writeImage(to: firstURL)
        try fixture.writeImage(to: secondURL)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        await model.importPhoto(from: firstURL)
        let previousURL = try #require(model.backgroundImageURL)
        let previousData = try Data(contentsOf: previousURL)
        let previousSelection = model.selection
        driver.applyError = CameraEffectsFixtureError.rejected

        await model.importPhoto(from: secondURL)

        #expect(model.backgroundImageURL == previousURL)
        #expect(model.selection == previousSelection)
        #expect(try fixture.saved() == previousSelection)
        #expect(try Data(contentsOf: previousURL) == previousData)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.images, includingPropertiesForKeys: nil)
        #expect(remaining.map(\.lastPathComponent) == [previousURL.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(model.error != nil)
    }

    @Test(arguments: InvalidPhotoSource.allCases)
    func invalidPhotoDoesNotReplaceASavedBackground(source: InvalidPhotoSource) async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences(background: .blur)
        try fixture.save(original)
        let invalidURL = fixture.root.appendingPathComponent("invalid.png")
        switch source {
        case .missing: break
        case .text: try Data("This is not an image.".utf8).write(to: invalidURL)
        case .directory: try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
        }
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        let applyCount = driver.applied.count

        await model.importPhoto(from: invalidURL)

        #expect(model.selection == original)
        #expect(try fixture.saved() == original)
        #expect(driver.applied.count == applyCount)
        #expect(model.error != nil)
        #expect(!model.isApplying)
    }

    @Test func missingDriverReportsUnavailabilityWithoutClaimingToApplySettings() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let original = CameraEffectsPreferences()
        let model = CameraEffectsModel(driver: nil, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }

        await model.prepare()
        #expect(model.error != nil)
        #expect(model.status == nil)
        await model.setBackground(.blur)
        #expect(model.error != nil)
        #expect(model.selection == original)
        #expect(fixture.defaults.data(forKey: CameraEffectsFixture.preferenceKey) == nil)
        await model.startPreview()
        #expect(model.preview == nil)
        #expect(model.error != nil)
        #expect(!model.isStartingPreview)
    }

    @Test func closingReleasesThePreviewAndPreservesSavedPreferences() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let saved = CameraEffectsPreferences(background: .blur, autoFraming: true)
        try fixture.save(saved)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        await model.prepare()

        await model.startPreview()
        #expect(model.preview === driver.previewView)
        #expect(driver.previewStarts == 1)
        #expect(driver.previewActive)
        model.close()

        #expect(model.preview == nil)
        #expect(!driver.previewActive)
        #expect(driver.closeCalls == 1)
        #expect(try fixture.saved() == saved)
    }

    @Test func closingWhilePreviewStartsPreventsALateViewFromReappearing() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        await model.prepare()
        driver.pausePreview = true
        let operation = Task { await model.startPreview() }
        try await waitUntil { driver.pendingPreview != nil }

        model.close()
        driver.finishPreview()
        await operation.value

        #expect(model.preview == nil)
        #expect(!model.isStartingPreview)
        #expect(!driver.previewActive)
        #expect(driver.closeCalls == 1)
    }

    @Test func asynchronousPreviewFailureRemovesThePreviewAndSurfacesTheError() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let saved = CameraEffectsPreferences(background: .blur, autoFraming: true)
        try fixture.save(saved)
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        await model.startPreview()
        #expect(model.preview === driver.previewView)

        let message = "The preview camera disconnected."
        await Task {
            await Task.yield()
            driver.previewActive = false
            driver.onCameraEffectsChanged?(CameraEffectsStatus(
                supportsBlur: true, supportsImageBackgrounds: true, canAddImages: true,
                isPreviewing: false, appliedPreferences: saved, previewError: message))
        }.value

        #expect(model.preview == nil)
        #expect(model.error == message)
        #expect(model.status?.isPreviewing == false)
        #expect(model.selection == saved)
        #expect(try fixture.saved() == saved)
        #expect(!model.isStartingPreview)
    }

    @Test func switchingCameraRemovesStoppedPreviewWithoutAnError() async throws {
        let fixture = try CameraEffectsFixture()
        defer { fixture.remove() }
        let driver = CameraEffectsProbe()
        let model = CameraEffectsModel(driver: driver, preferences: fixture.defaults, directory: fixture.images)
        defer { model.close() }
        await model.prepare()
        await model.startPreview()
        #expect(model.preview === driver.previewView)
        driver.previewActive = false
        driver.onCameraEffectsChanged?(CameraEffectsStatus(
            supportsBlur: true, supportsImageBackgrounds: true, canAddImages: true,
            isPreviewing: false, appliedPreferences: model.selection))
        #expect(model.preview == nil)
        #expect(model.error == nil)
        #expect(model.status?.isPreviewing == false)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CameraEffectsFixtureError.timeout }
            await Task.yield()
        }
    }
}

enum InvalidPhotoSource: CaseIterable, Sendable { case missing, text, directory }

@MainActor
private final class CameraEffectsFixture {
    static let preferenceKey = "camera.effects.v1"
    let suiteName = "CameraEffectsModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let images: URL

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        images = root.appendingPathComponent("Imported backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func save(_ preferences: CameraEffectsPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.preferenceKey)
    }

    func saved() throws -> CameraEffectsPreferences? {
        guard let data = defaults.data(forKey: Self.preferenceKey) else { return nil }
        return try JSONDecoder().decode(CameraEffectsPreferences.self, from: data)
    }

    func writeImage(to url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<18 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 51
                pixels[offset + 1] = 102
                pixels[offset + 2] = 179
                pixels[offset + 3] = 255
            }
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CameraEffectsFixtureError: LocalizedError {
    case rejected, timeout
    var errorDescription: String? {
        switch self {
        case .rejected: "The camera setting was rejected."
        case .timeout: "The expected camera settings operation did not begin."
        }
    }
}

@MainActor
private final class CameraEffectsProbe: CameraEffectsDriver {
    var onCameraEffectsChanged: (@MainActor (CameraEffectsStatus) -> Void)?
    var preferred = CameraEffectsPreferences()
    var applied: [CameraEffectsPreferences] = []
    var prepareCalls = 0
    var previewStarts = 0
    var previewActive = false
    var closeCalls = 0
    var applyError: (any Error)?
    var confirmsApply = true
    var pauseApply = false
    var pausePreview = false
    var pendingApply: CheckedContinuation<Void, Never>?
    var pendingPreview: CheckedContinuation<Void, Never>?
    let previewView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))

    func setPreferredCameraEffects(_ preferences: CameraEffectsPreferences) { preferred = preferences }

    func prepareCameraEffects() async throws -> CameraEffectsStatus {
        prepareCalls += 1
        return status(preferences: preferred)
    }

    func applyCameraEffects(_ preferences: CameraEffectsPreferences) async throws -> CameraEffectsStatus {
        applied.append(preferences)
        if pauseApply { await withCheckedContinuation { pendingApply = $0 } }
        if let applyError { throw applyError }
        var result = status(preferences: preferences)
        if !confirmsApply { result.appliedPreferences = nil }
        return result
    }

    func startCameraEffectsPreview() async throws -> NSView {
        previewStarts += 1
        previewActive = true
        if pausePreview { await withCheckedContinuation { pendingPreview = $0 } }
        return previewView
    }

    func stopCameraEffectsPreview() { previewActive = false }
    func closeCameraEffects() { closeCalls += 1; previewActive = false }

    func finishApply() {
        let continuation = pendingApply
        pendingApply = nil
        continuation?.resume()
    }

    func finishPreview() {
        let continuation = pendingPreview
        pendingPreview = nil
        continuation?.resume()
    }

    private func status(preferences: CameraEffectsPreferences) -> CameraEffectsStatus {
        CameraEffectsStatus(supportsBlur: true, supportsImageBackgrounds: true, canAddImages: true,
                            isPreviewing: previewActive, appliedPreferences: preferences)
    }
}
