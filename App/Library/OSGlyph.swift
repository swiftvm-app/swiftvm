import SwiftUI
import VMCore

/// The icon that identifies a guest operating system, with the machine's status dot.
///
/// Uses generic symbols rather than vendor logos.
struct OSGlyph: View {
    let os: GuestOS
    var state: VMState?
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size + 10, height: size + 10)
            .overlay(alignment: .bottomTrailing) {
                if let state, let color = StatusDot.color(for: state) {
                    StatusDot(color: color, isPulsing: state.isTransitioning)
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch os.family {
        case .macOS: "apple.logo"
        case .windows: "square.grid.2x2.fill"
        case .linux:
            switch os.distribution {
            case "ubuntu": "leaf.fill"
            case "debian": "hurricane"
            case "fedora": "f.circle.fill"
            default: "terminal.fill"
            }
        }
    }

    private var tint: Color {
        switch os.family {
        case .macOS: .green
        case .windows: .blue
        case .linux:
            switch os.distribution {
            case "ubuntu": .orange
            case "debian": .red
            case "fedora": .indigo
            default: .teal
            }
        }
    }
}

/// The small dot that shows whether a machine is running (green) or suspended (blue).
struct StatusDot: View {
    let color: Color
    var isPulsing = false

    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
            .opacity(isPulsing && isDimmed ? 0.35 : 1)
            .onAppear { animateIfNeeded() }
            .onChange(of: isPulsing) { animateIfNeeded() }
    }

    private func animateIfNeeded() {
        if isPulsing {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isDimmed = true }
        } else {
            withAnimation(.default) { isDimmed = false }
        }
    }

    static func color(for state: VMState) -> Color? {
        switch state {
        case .stopped: nil
        case .running, .starting, .restoring: .green
        case .paused: .yellow
        case .suspended, .suspending: .blue
        case .stopping: .orange
        }
    }
}
