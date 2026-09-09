import CoreGraphics

enum MeetingSelfViewLayout {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    static func nearestCorner(to point: CGPoint, in size: CGSize) -> Corner {
        if point.y < size.height / 2 { return point.x < size.width / 2 ? .topLeft : .topRight }
        return point.x < size.width / 2 ? .bottomLeft : .bottomRight
    }

    /// Top corners tuck against the edge until the toolbar needs its clearance.
    static func frame(in size: CGSize, aspectRatio: Double, compactHeight: Bool, corner: Corner = .topRight, showsControls: Bool = true) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let inset = min(16, size.width * 0.04)
        let toolbarClearance = min(compactHeight ? 54.0 : 70.0, size.height * 0.2)
        let top = showsControls ? toolbarClearance : inset
        let ratio = aspectRatio.isFinite && (0.125...8).contains(aspectRatio) ? aspectRatio : 16.0 / 9.0
        let availableHeight = max(0, min(144, size.height * 0.28, size.height - toolbarClearance - 90))
        let width = max(0, min(180, max(96, size.width * 0.22), size.width - inset * 2, availableHeight * ratio))
        let x = corner == .topLeft || corner == .bottomLeft ? inset : max(inset, size.width - inset - width)
        let y = corner == .topLeft || corner == .topRight ? top : max(toolbarClearance, size.height - 90 - width / ratio)
        return CGRect(x: x, y: y, width: width, height: width / ratio)
    }
}
