import SwiftUI
import VMCore

/// The tile that stands for a guest operating system wherever a machine is shown: a rounded square in
/// the system's colour with its symbol in white, made the way the icons in System Settings are.
///
/// Uses generic symbols rather than vendor logos.
struct OSGlyph: View {
    let os: GuestOS
    /// The side of the tile.
    var size: CGFloat = 44
    /// Whether the tile is in colour. The tile of a machine that is off is not.
    var isLit = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Image(systemName: os.glyphSymbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background {
                if isLit {
                    shape.fill(os.glyphTint.gradient)
                } else {
                    shape.fill(.primary.opacity(0.08))
                }
            }
            .accessibilityHidden(true)
    }
}

extension GuestOS {
    /// The symbol that stands for this system. Every Linux has the same one: what tells one
    /// distribution from another is the colour, and the name next to the tile.
    var glyphSymbol: String {
        switch family {
        case .macOS: "apple.logo"
        case .windows: "square.grid.2x2.fill"
        case .linux: "terminal"
        }
    }

    /// The colour of this system's tile. Each is dark enough for the white symbol on it.
    var glyphTint: Color {
        switch family {
        case .macOS: .blue
        case .windows: Color(red: 0, green: 0.6, blue: 0.82)
        case .linux:
            switch distribution {
            case "ubuntu": .orange
            case "debian": .red
            case "fedora": .indigo
            default: .gray
            }
        }
    }
}
