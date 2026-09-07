import SwiftUI
import YapMeetings

/// One centered group keeps the joining state calm at every window size.
/// The window's native backdrop still samples the desktop beneath this tint.
struct MeetingConnectionView: View {
    let title: String
    let status: MeetingStatus
    let cancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 360
            VStack(spacing: compact ? 12 : 24) {
                YapMark(size: compact ? 44 : 64)
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)

                VStack(spacing: compact ? 8 : 10) {
                    Text(title)
                        .font(.system(size: compact ? 19 : 23, weight: .semibold))
                        .tracking(-0.35)
                        .lineLimit(2).minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        if !reduceMotion {
                            ConnectionSpinner()
                        }
                        Text(status.label).font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                if status != .leaving {
                    Button(action: cancel) {
                        Text(cancelTitle)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .tint(nil as Color?).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 28).padding(.vertical, compact ? 12 : 20)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            if !reduceTransparency {
                ZStack {
                    Color.black.opacity(colorScheme == .dark ? 0.30 : 0)
                    RadialGradient(colors: [
                        Color(red: 0.12, green: 0.65, blue: 0.66)
                            .opacity(colorScheme == .dark ? 0.17 : 0.10),
                        .clear
                    ], center: .center, startRadius: 0, endRadius: 340)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }

    private var detail: String? {
        switch status {
        case .waitingForHost: "The meeting will begin when the host starts it."
        case .waitingRoom: "The host will let you in."
        default: nil
        }
    }

    private var cancelTitle: String {
        switch status {
        case .reconnecting: "Leave meeting…"
        case .waitingRoom: "Leave waiting room"
        default: "Cancel"
        }
    }
}

/// Uses the SwiftUI foreground color even when the native window's appearance
/// differs from its content, so the small indicator stays visible in dark mode.
private struct ConnectionSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(AngularGradient(colors: [.primary.opacity(0.08), .primary.opacity(0.7)], center: .center),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .frame(width: 12, height: 12)
            .animation(.linear(duration: 0.95).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}
