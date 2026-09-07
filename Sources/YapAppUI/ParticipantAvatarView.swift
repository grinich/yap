import SwiftUI
import ImageIO
import YapMeetings

struct ParticipantAvatarRequest: Hashable, Sendable {
    let sessionID: UUID
    let participantID: String
    let avatar: MeetingAvatar
}

/// Decode on this actor, off the UI thread, and share thumbnails between the
/// gallery, People and PiP. Bound both file input and retained decoded pixels.
actor ParticipantAvatarLoader {
    static let shared = ParticipantAvatarLoader()
    static let maximumFileBytes = 8 * 1_024 * 1_024
    private struct Entry { let image: CGImage? }
    private var cache: [ParticipantAvatarRequest: Entry] = [:]
    private var order: [ParticipantAvatarRequest] = []

    func image(for request: ParticipantAvatarRequest) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[request] { return cached.image }
        let image = Self.decode(request.avatar)
        cache[request] = Entry(image: image)
        order.append(request)
        if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        return image
    }

    private static func decode(_ avatar: MeetingAvatar) -> CGImage? {
        let url = URL(fileURLWithPath: avatar.path)
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize,
              size > 0, size <= maximumFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

struct ParticipantAvatarView: View {
    let participant: MeetingParticipant
    let sessionID: UUID?
    let diameter: CGFloat
    var fontSize: CGFloat? = nil
    var backgroundOpacity = 0.22
    @State private var loadedRequest: ParticipantAvatarRequest?
    @State private var image: CGImage?

    private var request: ParticipantAvatarRequest? {
        guard let sessionID, let avatar = participant.avatar else { return nil }
        return ParticipantAvatarRequest(sessionID: sessionID, participantID: participant.id, avatar: avatar)
    }

    var body: some View {
        ZStack {
            if let request, request == loadedRequest, let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Text(participant.initials)
                    .font(.system(size: fontSize ?? max(1, min(42, diameter * 0.42)), weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(YapTheme.palette[abs(participant.avatarSeed % YapTheme.palette.count)].opacity(backgroundOpacity))
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil; loadedRequest = nil
            guard let request else { return }
            let decoded = await ParticipantAvatarLoader.shared.image(for: request)
            guard !Task.isCancelled else { return }
            image = decoded; loadedRequest = request
        }
    }
}
