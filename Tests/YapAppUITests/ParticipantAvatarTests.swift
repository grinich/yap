import Foundation
import CoreGraphics
import ImageIO
import Testing
import YapMeetings
@testable import YapAppUI

struct ParticipantAvatarTests {
    @Test func onlySDKLocalPathsAreAccepted() {
        for path in ["", "relative.png", "https://example.com/avatar.png", "file:///tmp/avatar.png", "//server/avatar.png", "/tmp/\0avatar"] {
            #expect(MeetingAvatar(path: path) == nil)
        }
        #expect(MeetingAvatar(path: "/tmp/avatar with spaces.png") != nil)
    }

    @Test func photosAreDownsampledAndSharedBetweenViews() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("portrait.png")
        try writeImage(path, width: 1_024, height: 256)
        let loader = ParticipantAvatarLoader()
        let request = ParticipantAvatarRequest(sessionID: UUID(), participantID: "1", avatar: try #require(MeetingAvatar(path: path.path)))
        let first = try #require(await loader.image(for: request))
        let second = await loader.image(for: request)
        #expect(first.width == 256 && first.height == 64)
        #expect(first === second)
    }

    @Test func samePathUpdatesAndReusedIDsDoNotShowAnOldPhoto() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("portrait.png")
        try writeImage(path, width: 512, height: 128)
        let loader = ParticipantAvatarLoader(), session = UUID()
        let old = ParticipantAvatarRequest(sessionID: session, participantID: "1", avatar: try #require(MeetingAvatar(path: path.path)))
        #expect(await loader.image(for: old)?.height == 64)
        try writeImage(path, width: 512, height: 512)
        let updated = ParticipantAvatarRequest(sessionID: session, participantID: "1", avatar: try #require(MeetingAvatar(path: path.path, revision: 1)))
        let nextMeeting = ParticipantAvatarRequest(sessionID: UUID(), participantID: "1", avatar: old.avatar)
        let nextPerson = ParticipantAvatarRequest(sessionID: session, participantID: "2", avatar: old.avatar)
        #expect(await loader.image(for: updated)?.height == 256)
        #expect(await loader.image(for: nextMeeting)?.height == 256)
        #expect(await loader.image(for: nextPerson)?.height == 256)
    }

    @Test func downloadCompletionCanRecoverFromAnUnreadableFile() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("portrait.png")
        try Data("not an image".utf8).write(to: path)
        let loader = ParticipantAvatarLoader(), session = UUID()
        let pending = ParticipantAvatarRequest(sessionID: session, participantID: "1", avatar: try #require(MeetingAvatar(path: path.path)))
        #expect(await loader.image(for: pending) == nil)
        try writeImage(path, width: 128, height: 128)
        let completed = ParticipantAvatarRequest(sessionID: session, participantID: "1", avatar: try #require(MeetingAvatar(path: path.path, revision: 1)))
        #expect(await loader.image(for: completed) != nil)
    }

    @Test func missingDirectoryAndOversizedInputsFallBack() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appendingPathComponent("large.png")
        try Data(repeating: 0, count: ParticipantAvatarLoader.maximumFileBytes + 1).write(to: large)
        let loader = ParticipantAvatarLoader()
        for path in [directory, directory.appendingPathComponent("missing.png"), large] {
            let request = ParticipantAvatarRequest(sessionID: UUID(), participantID: "1", avatar: try #require(MeetingAvatar(path: path.path)))
            #expect(await loader.image(for: request) == nil)
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yap-avatar-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(_ url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
    }
}
