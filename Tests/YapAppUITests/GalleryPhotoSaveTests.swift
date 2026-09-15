import AppKit
import ImageIO
import Testing
@testable import YapAppUI

@Suite("Group photo automatic saving") @MainActor
struct GalleryPhotoSaveTests {
    @Test func writesADecodablePNGToTheRequestedDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try solidImage(red: 255, green: 0, blue: 0)

        let url = try GalleryPhotoCapture.writePhoto(image, to: directory)

        #expect(url.deletingLastPathComponent() == directory)
        #expect(url.pathExtension == "png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 16 && decoded.height == 9)
        try expectColor(at: url, red: 255, green: 0, blue: 0)
    }

    @Test func photosWithTheSameTimestampNeverOverwriteEachOther() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try GalleryPhotoCapture.writePhoto(solidImage(red: 255, green: 0, blue: 0), to: directory, now: now)
        let originalBytes = try Data(contentsOf: first)

        let second = try GalleryPhotoCapture.writePhoto(solidImage(red: 0, green: 0, blue: 255), to: directory, now: now)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == originalBytes)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2)
        try expectColor(at: second, red: 0, green: 0, blue: 255)
    }

    @Test func savingRecordsTheLocationAndRepeatedSavesDoNotCreateDuplicates() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var directoryLookups = 0
        let photo = GalleryPhotoCapture(downloadsDirectory: {
            directoryLookups += 1
            return directory
        })
        let image = try solidImage(red: 0, green: 255, blue: 0)
        photo.image = image

        photo.saveToDownloads()

        let savedURL = try #require(photo.savedURL)
        let originalBytes = try Data(contentsOf: savedURL)
        #expect(savedURL.deletingLastPathComponent() == directory)
        #expect(photo.saveError == nil)
        #expect(photo.image === image)
        try expectColor(at: savedURL, red: 0, green: 255, blue: 0)

        photo.saveToDownloads()

        #expect(photo.savedURL == savedURL)
        #expect(photo.saveError == nil)
        #expect(directoryLookups == 1)
        #expect(try Data(contentsOf: savedURL) == originalBytes)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func failedSaveKeepsThePhotoAndCanRetryWhenDownloadsBecomesAvailable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let blockingBytes = Data("This path is a file, not a directory.".utf8)
        try blockingBytes.write(to: downloads)
        let photo = GalleryPhotoCapture(downloadsDirectory: { downloads })
        let image = try solidImage(red: 255, green: 0, blue: 0)
        photo.image = image

        photo.saveToDownloads()

        #expect(photo.savedURL == nil)
        #expect(try #require(photo.saveError).isEmpty == false)
        #expect(photo.image === image)
        #expect(try Data(contentsOf: downloads) == blockingBytes)

        try FileManager.default.removeItem(at: downloads)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        photo.saveToDownloads()

        let savedURL = try #require(photo.savedURL)
        #expect(savedURL.deletingLastPathComponent() == downloads)
        #expect(photo.saveError == nil)
        #expect(photo.image === image)
        try expectColor(at: savedURL, red: 255, green: 0, blue: 0)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-photo-save-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> NSImage {
        let pixel: [UInt8] = [red, green, blue, 255]
        let bytes = Array(repeating: pixel, count: 16 * 9).flatMap { $0 }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 16, height: 9, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 16, height: 9))
    }

    private func expectColor(at url: URL, red: UInt8, green: UInt8, blue: UInt8) throws {
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3 && !bitmap.isPlanar)
        let pixels = try #require(bitmap.bitmapData)
        let offset = 4 * bitmap.bytesPerRow + 8 * bitmap.samplesPerPixel
        let actual = Array(UnsafeBufferPointer(start: pixels + offset, count: 3))
        #expect(actual == [red, green, blue])
    }
}
