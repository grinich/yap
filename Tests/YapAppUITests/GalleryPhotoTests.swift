import AppKit
import Testing
@testable import YapAppUI

@Suite("Group photo export") @MainActor
struct GalleryPhotoTests {
    @Test func collageUsesEveryFeedWithoutAddingLabelsAndCentersLastRow() throws {
        func solid(_ color: NSColor) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
                bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            return try #require(context.makeImage())
        }
        let photo = try GalleryPhotoCapture.collage([solid(.red), solid(.green), solid(.blue)])
        #expect(photo.size == NSSize(width: 320, height: 180))
        let tiff = try #require(photo.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let pixels = try #require(bitmap.bitmapData)
        // Top-left and top-right feeds, then centered blue with a black margin.
        func rgb(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
            return Array(UnsafeBufferPointer(start: pixels + offset, count: 3))
        }
        #expect(rgb(80, 45) == [255, 0, 0])
        #expect(rgb(240, 45) == [0, 255, 0])
        #expect(rgb(160, 135) == [0, 0, 255])
        #expect(rgb(20, 135) == [0, 0, 0])
    }
    @Test func shutterIsBoundedPCMAndDecodesAsASound() throws {
        let pcm = GalleryPhotoCapture.shutterPCM()
        #expect(pcm.count == 26460)
        #expect(NSSound(data: GalleryPhotoCapture.wave(pcm)) != nil)
        #expect(throws: (any Error).self) { try GalleryPhotoCapture.collage([]) }
    }

    @Test func batchCaptureIncludesAll200ParticipantsInOrderAndReleasesEachBatch() async throws {
        let participantIDs = (0..<200).map { "person-\($0)" }
        let probe = BatchCaptureProbe()

        let frames = try await GalleryPhotoBatchCapture.collect(
            participantIDs: participantIDs,
            prepare: probe.prepare,
            capture: probe.capture,
            release: probe.release
        )

        #expect(frames == participantIDs)
        #expect(Set(frames).count == 200)
        #expect(probe.prepared.map(\.count) == [49, 49, 49, 49, 4])
        #expect(probe.prepared.flatMap { $0 } == participantIDs)
        #expect(probe.captured == probe.prepared)
        #expect(probe.released == probe.prepared)
        #expect(probe.batchIndices == [0, 1, 2, 3, 4])
        #expect(probe.batchTotals == [5, 5, 5, 5, 5])
        #expect(probe.subscribedIDs.isEmpty)
    }

    @Test func batchedCollageContainsEachOf200DistinctCameraImagesExactlyOnce() async throws {
        let participantIDs = (0..<200).map { "person-\($0)" }
        let colors: [[UInt8]] = (0..<200).map { (index: Int) -> [UInt8] in
            let red = UInt8(index + 1)
            let green = UInt8(255 - index)
            let blue = UInt8((index * 37) % 256)
            return [red, green, blue]
        }
        let images = try colors.map { color in
            let bytes = Array(repeating: color + [255], count: 16 * 9).flatMap { $0 }
            let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
            return try #require(CGImage(width: 16, height: 9, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let imagesByID = Dictionary(uniqueKeysWithValues: zip(participantIDs, images))
        let probe = BatchCaptureProbe()
        let frames = try await GalleryPhotoBatchCapture.collect(
            participantIDs: participantIDs,
            prepare: probe.prepare,
            capture: { ids, index, total in
                try probe.capture(ids, index, total).map { try #require(imagesByID[$0]) }
            },
            release: probe.release
        )

        let photo = try GalleryPhotoCapture.collage(frames)
        #expect(photo.size == NSSize(width: 240, height: 126))
        #expect(probe.prepared.map(\.count) == [49, 49, 49, 49, 4])
        #expect(probe.released == probe.prepared)
        #expect(probe.subscribedIDs.isEmpty)
        let tiff = try #require(photo.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let pixels = try #require(bitmap.bitmapData)
        #expect(bitmap.pixelsWide == 240)
        #expect(bitmap.pixelsHigh == 126)
        try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3 && !bitmap.isPlanar)

        // Fifteen columns fill thirteen rows; the last five cameras are centered.
        var sampledColors: [[UInt8]] = []
        for index in participantIDs.indices {
            let row = index / 15, column = index % 15
            let leftMargin = row == 13 ? 80 : 0
            let x = leftMargin + column * 16 + 8
            let y = row * 9 + 4
            let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
            let actualColor = Array(UnsafeBufferPointer(start: pixels + offset, count: 3))
            #expect(actualColor == colors[index], "Camera \(participantIDs[index]) must occupy its own tile")
            sampledColors.append(actualColor)
        }
        #expect(Set(sampledColors).count == 200)
    }

    @Test(arguments: [0, 1, 49, 50])
    func batchCaptureHandlesEmptyAndBoundaryParticipantCounts(count: Int) async throws {
        let participantIDs = (0..<count).map { "person-\($0)" }
        let probe = BatchCaptureProbe()
        let expectedSizes: [Int: [Int]] = [0: [], 1: [1], 49: [49], 50: [49, 1]]

        let frames = try await GalleryPhotoBatchCapture.collect(
            participantIDs: participantIDs,
            prepare: probe.prepare,
            capture: probe.capture,
            release: probe.release
        )

        #expect(frames == participantIDs)
        #expect(probe.prepared.map(\.count) == expectedSizes[count])
        #expect(probe.captured == probe.prepared)
        #expect(probe.released == probe.prepared)
        #expect(probe.batchIndices == Array(probe.prepared.indices))
        #expect(probe.batchTotals == Array(repeating: probe.prepared.count, count: probe.prepared.count))
        #expect(probe.subscribedIDs.isEmpty)
    }

    @Test(arguments: BatchFailureStage.allCases)
    func batchCaptureFailureReleasesSubscriptionsAndDoesNotReturnPartialFrames(stage: BatchFailureStage) async {
        let participantIDs = (0..<120).map { "person-\($0)" }
        let probe = BatchCaptureProbe()
        var returnedFrames: [String]?

        await #expect(throws: BatchTestError.injected) {
            returnedFrames = try await GalleryPhotoBatchCapture.collect(
                participantIDs: participantIDs,
                prepare: { ids, index, total in
                    probe.prepare(ids, index, total)
                    if index == 1, stage == .prepare { throw BatchTestError.injected }
                },
                capture: { ids, index, total in
                    let frames = probe.capture(ids, index, total)
                    if index == 1, stage == .capture { throw BatchTestError.injected }
                    return frames
                },
                release: probe.release
            )
        }

        #expect(returnedFrames == nil)
        #expect(probe.prepared.map(\.count) == [49, 49])
        #expect(probe.captured.count == (stage == .prepare ? 1 : 2))
        #expect(probe.released == probe.prepared)
        #expect(probe.subscribedIDs.isEmpty)
    }

    @Test(arguments: [-1, 1])
    func batchCaptureRejectsMissingOrExtraFramesAndReleasesSubscriptions(frameCountChange: Int) async {
        let participantIDs = (0..<120).map { "person-\($0)" }
        let probe = BatchCaptureProbe()
        var returnedFrames: [String]?

        await #expect(throws: (any Error).self) {
            returnedFrames = try await GalleryPhotoBatchCapture.collect(
                participantIDs: participantIDs,
                prepare: probe.prepare,
                capture: { ids, index, total in
                    let frames = probe.capture(ids, index, total)
                    guard index == 1 else { return frames }
                    return frameCountChange < 0 ? Array(frames.dropLast()) : frames + ["unexpected-frame"]
                },
                release: probe.release
            )
        }

        #expect(returnedFrames == nil)
        #expect(probe.prepared.map(\.count) == [49, 49])
        #expect(probe.captured == probe.prepared)
        #expect(probe.released == probe.prepared)
        #expect(probe.subscribedIDs.isEmpty)
    }

    @Test func cancellationDuringFinalCaptureReleasesSubscriptionsAndDoesNotReturnFrames() async {
        let participantIDs = (0..<50).map { "person-\($0)" }
        let probe = BatchCaptureProbe()
        let operation = Task {
            try await GalleryPhotoBatchCapture.collect(
                participantIDs: participantIDs,
                prepare: probe.prepare,
                capture: { ids, index, total in
                    let frames = probe.capture(ids, index, total)
                    if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    return frames
                },
                release: probe.release
            )
        }

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(probe.prepared.map(\.count) == [49, 1])
        #expect(probe.captured == probe.prepared)
        #expect(probe.released == probe.prepared)
        #expect(probe.subscribedIDs.isEmpty)
    }

    @Test func alreadyCancelledBatchCaptureDoesNotSubscribeOrCapture() async {
        let probe = BatchCaptureProbe()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GalleryPhotoBatchCapture.collect(
                participantIDs: ["person-0"],
                prepare: probe.prepare,
                capture: probe.capture,
                release: probe.release
            )
        }

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(probe.prepared.isEmpty)
        #expect(probe.captured.isEmpty)
        #expect(probe.subscribedIDs.isEmpty)
    }
}

private enum BatchTestError: Error, Equatable { case injected }

enum BatchFailureStage: CaseIterable, Sendable { case prepare, capture }

@MainActor
private final class BatchCaptureProbe {
    var subscribedIDs: [String] = []
    var prepared: [[String]] = []
    var captured: [[String]] = []
    var released: [[String]] = []
    var batchIndices: [Int] = []
    var batchTotals: [Int] = []

    func prepare(_ ids: [String], _ index: Int, _ total: Int) {
        // A new batch must never overlap the previous batch's video subscriptions.
        #expect(subscribedIDs.isEmpty)
        #expect(!ids.isEmpty)
        #expect(ids.count <= 49)
        subscribedIDs = ids
        prepared.append(ids)
        batchIndices.append(index)
        batchTotals.append(total)
    }

    func capture(_ ids: [String], _ index: Int, _ total: Int) -> [String] {
        #expect(subscribedIDs == ids)
        #expect(batchIndices.last == index)
        #expect(batchTotals.last == total)
        captured.append(ids)
        return ids
    }

    func release() {
        if !subscribedIDs.isEmpty { released.append(subscribedIDs) }
        subscribedIDs.removeAll()
    }
}
