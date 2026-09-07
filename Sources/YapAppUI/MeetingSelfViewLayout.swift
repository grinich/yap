import CoreGraphics

enum MeetingSelfViewLayout {
    /// Leaves the top toolbar and bottom call controls clear, even at 320×300.
    static func frame(in size: CGSize, aspectRatio: Double, compactHeight: Bool) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let inset = min(16, size.width * 0.04)
        let top = min(compactHeight ? 54.0 : 70.0, size.height * 0.2)
        let ratio = aspectRatio.isFinite && (0.125...8).contains(aspectRatio) ? aspectRatio : 16.0 / 9.0
        let availableHeight = max(0, min(144, size.height * 0.28, size.height - top - 90))
        let width = max(0, min(180, max(96, size.width * 0.22), size.width - inset * 2, availableHeight * ratio))
        return CGRect(x: max(inset, size.width - inset - width), y: top, width: width, height: width / ratio)
    }
}
