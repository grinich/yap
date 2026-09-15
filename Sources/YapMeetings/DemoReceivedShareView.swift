import AppKit

enum DemoReceivedShareDocument: String, CaseIterable {
    case landscape, portrait

    var sourceID: String { "demo-received-\(rawValue)" }
    var title: String { "\(rawValue.capitalized) document (local preview)" }
    var size: NSSize { self == .landscape ? NSSize(width: 1600, height: 1000) : NSSize(width: 1000, height: 1600) }
}

/// Resolution-independent content for testing the production received-share host.
/// The fixed paper coordinates make fit, zoom, crop, and pan changes easy to inspect.
@MainActor
final class DemoReceivedShareView: NSView {
    let document: DemoReceivedShareDocument

    init(document: DemoReceivedShareDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Synthetic \(document.rawValue) shared document with a grid and four labeled corners. Local preview; no screen capture.")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { document.size }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()
        let size = document.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX - size.width * scale / 2, yBy: bounds.midY - size.height * scale / 2)
        transform.scale(by: scale)
        transform.concat()

        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let ink = NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.23, alpha: 1)
        let secondary = NSColor(calibratedRed: 0.32, green: 0.39, blue: 0.48, alpha: 1)
        drawText("YAP · LOCAL PREVIEW", in: NSRect(x: 44, y: 148, width: size.width - 88, height: 30),
                 size: 20, weight: .semibold, color: secondary)
        drawText("Shared-screen preview", in: NSRect(x: 44, y: 190, width: size.width - 88, height: 62),
                 size: 46, weight: .bold, color: ink)
        drawText("\(document.rawValue.capitalized) · \(Int(size.width)) × \(Int(size.height)) · No screen is being captured",
                 in: NSRect(x: 44, y: 263, width: size.width - 88, height: 38), size: 23, color: secondary)

        let grid = NSRect(x: 44, y: 328, width: size.width - 88, height: size.height - 518)
        let columns = document == .landscape ? 6 : 4
        let rows = document == .landscape ? 4 : 8
        let cellWidth = grid.width / CGFloat(columns), cellHeight = grid.height / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = NSRect(x: grid.minX + CGFloat(column) * cellWidth,
                                  y: grid.minY + CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
                NSColor(calibratedWhite: (row + column).isMultiple(of: 2) ? 1 : 0.94, alpha: 1).setFill()
                cell.fill()
                NSColor(calibratedWhite: 0.79, alpha: 1).setStroke()
                let border = NSBezierPath(rect: cell)
                border.lineWidth = 1
                border.stroke()
                drawText("R\(row + 1) · C\(column + 1)", in: cell.insetBy(dx: 14, dy: 14),
                         size: 24, weight: .semibold, color: ink)
                drawText("Fine detail · 200%", in: NSRect(x: cell.minX + 14, y: cell.minY + 57,
                                                       width: cell.width - 28, height: 28), size: 16, color: secondary)
            }
        }
        drawText("Pan to all four corners. Switch documents to compare aspect ratios.",
                 in: NSRect(x: 44, y: size.height - 165, width: size.width - 88, height: 32), size: 22, color: secondary)

        drawCorner("A · TOP LEFT", coordinates: "0, 0", x: 28, y: 28,
                   color: NSColor(calibratedRed: 0.11, green: 0.34, blue: 0.74, alpha: 1))
        drawCorner("B · TOP RIGHT", coordinates: "\(Int(size.width)), 0", x: size.width - 318, y: 28,
                   color: NSColor(calibratedRed: 0.43, green: 0.24, blue: 0.67, alpha: 1))
        drawCorner("C · BOTTOM LEFT", coordinates: "0, \(Int(size.height))", x: 28, y: size.height - 116,
                   color: NSColor(calibratedRed: 0.04, green: 0.43, blue: 0.38, alpha: 1))
        drawCorner("D · BOTTOM RIGHT", coordinates: "\(Int(size.width)), \(Int(size.height))", x: size.width - 318, y: size.height - 116,
                   color: NSColor(calibratedRed: 0.65, green: 0.29, blue: 0.08, alpha: 1))
    }

    private func drawCorner(_ title: String, coordinates: String, x: CGFloat, y: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 290, height: 88), xRadius: 12, yRadius: 12).fill()
        drawText(title, in: NSRect(x: x + 15, y: y + 15, width: 260, height: 30), size: 21, weight: .bold, color: .white)
        drawText(coordinates, in: NSRect(x: x + 15, y: y + 50, width: 260, height: 26), size: 18, color: .white)
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat,
                          weight: NSFont.Weight = .regular, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
}
