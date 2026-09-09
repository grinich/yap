import SwiftUI
import AppKit

enum YapTheme {
    static let accent = Color(nsColor: .controlAccentColor)
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.48),
        Color(red: 0.55, green: 0.45, blue: 0.36),
        Color(red: 0.40, green: 0.46, blue: 0.62),
        Color(red: 0.58, green: 0.40, blue: 0.45),
        Color(red: 0.47, green: 0.43, blue: 0.61),
        Color(red: 0.47, green: 0.52, blue: 0.33)
    ]
}

/// A single light, frosted backdrop that samples windows behind Yap.
/// Text, video and controls remain fully opaque. Keep the material active while
/// another app has focus so the surround does not turn into a solid gray panel.
struct YapWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct YapMark: View {
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "YapIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text("Y")
                    .font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(YapTheme.accent.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct StatusPill: View {
    var title: String
    var symbol: String
    var color: Color = .secondary
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.08), in: Capsule())
    }
}

struct CardSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08), lineWidth: 1))
    }
}

/// A single native glass layer for floating groups of controls. Content surfaces
/// use ordinary materials instead; never nest this around glass-styled buttons.
struct YapGlassSurface<Surface: InsettableShape>: ViewModifier {
    var shape: Surface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(.primary.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
    func yapGlassSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(YapGlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius)))
    }

    /// Only the inset edge rounds independently. The native window clips the
    /// trailing edge, avoiding a second curve inside its top and bottom corners.
    func yapTrailingPanelSurface() -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22)
        return modifier(YapGlassSurface(shape: shape)).clipShape(shape)
    }
}
