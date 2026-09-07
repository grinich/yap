import SwiftUI

/// Rows share a height, but each video retains its incoming aspect ratio.
/// Portrait rows can grow taller instead of wasting their width on side bars.
struct MeetingTileArrangement {
    static func frames(aspectRatios: [Double], size: CGSize, spacing: CGFloat) -> [CGRect] {
        guard !aspectRatios.isEmpty else { return [] }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return aspectRatios.map { _ in .zero }
        }
        let ratios = aspectRatios.map { $0.isFinite && (0.125...8).contains($0) ? CGFloat($0) : 16 / 9 }
        let gap = spacing.isFinite ? max(0, spacing) : 0
        let average = ratios.reduce(0, +) / CGFloat(ratios.count)
        var bestArea: CGFloat = -1
        var best = ratios.map { _ in CGRect.zero }
        for columns in 1...ratios.count {
            let rows = stride(from: 0, to: ratios.count, by: columns).map { start in
                start..<min(start + columns, ratios.count)
            }
            let heights = rows.map { row in
                // Reserve the missing slots in the last row so one leftover
                // participant does not become disproportionately large.
                let sum = row.reduce(CGFloat.zero) { $0 + ratios[$1] } + CGFloat(columns - row.count) * average
                return max(0, size.width - CGFloat(columns - 1) * gap) / sum
            }
            let naturalHeight = heights.reduce(0, +)
            guard naturalHeight > 0 else { continue }
            let scale = min(1, max(0, size.height - CGFloat(rows.count - 1) * gap) / naturalHeight)
            let area = zip(rows, heights).reduce(CGFloat.zero) { total, item in
                total + item.0.reduce(CGFloat.zero) { $0 + ratios[$1] } * pow(item.1 * scale, 2)
            }
            guard area > bestArea else { continue }
            bestArea = area
            var frames: [CGRect] = []
            var y = max(0, (size.height - naturalHeight * scale - CGFloat(rows.count - 1) * gap) / 2)
            for (row, natural) in zip(rows, heights) {
                let height = natural * scale
                let width = row.reduce(CGFloat.zero) { $0 + ratios[$1] * height } + CGFloat(row.count - 1) * gap
                var x = (size.width - width) / 2
                for index in row {
                    let width = ratios[index] * height
                    frames.append(CGRect(x: x, y: y, width: width, height: height))
                    x += width + gap
                }
                y += height + gap
            }
            best = frames
        }
        return bestArea > 0 ? best : ratios.map { _ in .zero }
    }
}

struct MeetingTileLayout: Layout {
    var aspectRatios: [Double]
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 450))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ratios = subviews.indices.map { aspectRatios.indices.contains($0) ? aspectRatios[$0] : 16 / 9 }
        let frames = MeetingTileArrangement.frames(aspectRatios: ratios, size: bounds.size, spacing: spacing)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
