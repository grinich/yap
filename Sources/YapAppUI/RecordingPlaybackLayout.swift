import AppKit

/// Tiny layout previews for Zoom's recording views, without a monitor frame.
enum RecordingPlaybackLayout: CaseIterable, Hashable, Sendable {
    case screenAndSpeaker, screenAndGallery, screenWithCaptions, speaker, gallery, screen

    init(recordingType: String?) {
        switch recordingType {
        case "shared_screen_with_speaker_view": self = .screenAndSpeaker
        case "shared_screen_with_gallery_view": self = .screenAndGallery
        case "shared_screen_with_speaker_view(CC)": self = .screenWithCaptions
        case "active_speaker", "speaker_view": self = .speaker
        case "gallery_view": self = .gallery
        default: self = .screen
        }
    }

    @MainActor var image: NSImage { Self.images[self]! }

    @MainActor private static let images = Dictionary(uniqueKeysWithValues: allCases.map { layout in
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
                let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                        xRadius: 1.1, yRadius: 1.1)
                path.lineWidth = 1.2
                path.stroke()
            }

            switch layout {
            case .gallery:
                for column in 0..<3 {
                    for row in 0..<2 {
                        box(1 + CGFloat(column) * 8, 1.5 + CGFloat(row) * 7, 6, 5.5)
                    }
                }
            case .speaker:
                box(1, 1, 22, 14)
                NSBezierPath(ovalIn: NSRect(x: 10, y: 8, width: 4, height: 4)).fill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: 3, width: 8, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            case .screen:
                box(1, 1, 22, 14)
            case .screenAndSpeaker, .screenWithCaptions:
                box(1, 1, 14, 14)
                box(18, 9, 5, 6)
                if layout == .screenWithCaptions {
                    let captions = NSBezierPath()
                    captions.move(to: NSPoint(x: 4, y: 4))
                    captions.line(to: NSPoint(x: 12, y: 4))
                    captions.lineWidth = 1.2
                    captions.stroke()
                }
            case .screenAndGallery:
                box(1, 1, 14, 14)
                for row in 0..<3 { box(18, 1 + CGFloat(row) * 5.5, 5, 3) }
            }
            return true
        }
        image.isTemplate = true
        return (layout, image)
    })
}
