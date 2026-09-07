import SwiftUI

private struct WhooshIconHover: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var showsHover: Bool { isHovered && isEnabled && !isSelected }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(showsHover ? (contrast == .increased ? 0.08 : 0.05) : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsHover)
    }
}

extension View {
    /// Add hover feedback without replacing a control's style or selected fill.
    func whooshIconHover(isSelected: Bool = false, cornerRadius: CGFloat = 10) -> some View {
        modifier(WhooshIconHover(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
