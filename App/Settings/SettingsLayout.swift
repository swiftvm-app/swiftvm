import SwiftUI

/// One page of a settings window: its row in the sidebar and the header at the top of the page.
nonisolated protocol SettingsPane: Hashable, Identifiable {
    var title: String { get }
    /// The SF Symbol on the pane's tile.
    var symbol: String { get }
    /// The colour of the pane's tile. Dark enough for the white symbol on it.
    var tint: Color { get }
    /// One line under the title, at the top of the page.
    var summary: String { get }
}

nonisolated extension SettingsPane {
    var id: Self { self }
}

/// The tile that stands for a settings pane: a rounded square in the pane's colour with its symbol in
/// white, as in System Settings.
struct SettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A settings window: the panes in a sidebar on the left, and the one that is chosen on the right.
///
/// The sidebar can't be hidden or resized, as there is nothing else to get to the panes with.
struct SettingsSplitView<Pane: SettingsPane, SidebarHeader: View, Detail: View>: View {
    let panes: [Pane]
    @Binding var selection: Pane
    @ViewBuilder var sidebarHeader: SidebarHeader
    @ViewBuilder var detail: (Pane) -> Detail

    @FocusState private var isSidebarFocused: Bool

    static var sidebarWidth: CGFloat { 216 }

    // Laid out by hand rather than with NavigationSplitView, which in a window of a fixed size and in a
    // sheet leaves its sidebar empty.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.primary.opacity(0.035))
            Divider()
            detail(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Each pane starts at its top, rather than where the last one was scrolled to.
                .id(selection)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(panes) { pane in
                        SettingsSidebarRow(pane: pane, isSelected: pane == selection) {
                            selection = pane
                            isSidebarFocused = true
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .focusable()
        .focused($isSidebarFocused)
        .focusEffectDisabled()
        // The arrow keys go through the panes, as in a list.
        .onMoveCommand { direction in
            guard let index = panes.firstIndex(of: selection) else { return }
            switch direction {
            case .up where index > 0: selection = panes[index - 1]
            case .down where index < panes.count - 1: selection = panes[index + 1]
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }
}

/// A pane in the sidebar: its tile and title, on the accent colour while it is the one shown.
private struct SettingsSidebarRow<Pane: SettingsPane>: View {
    let pane: Pane
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsTile(symbol: pane.symbol, tint: pane.tint)
                Text(pane.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .foregroundStyle(isSelected && isKey ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isKey ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.1)))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selection is in colour only in the window in front, as in every sidebar.
    private var isKey: Bool {
        controlActiveState == .key || controlActiveState == .active
    }
}

extension SettingsSplitView where SidebarHeader == EmptyView {
    init(panes: [Pane], selection: Binding<Pane>, @ViewBuilder detail: @escaping (Pane) -> Detail) {
        self.init(panes: panes, selection: selection, sidebarHeader: { EmptyView() }, detail: detail)
    }
}

/// The pane's tile, title and what it is for, at the top of its page. The first thing in its form.
struct SettingsPaneHeader<Pane: SettingsPane>: View {
    let pane: Pane

    var body: some View {
        Section {
            VStack(spacing: 6) {
                SettingsTile(symbol: pane.symbol, tint: pane.tint, size: 44)
                    .padding(.bottom, 2)
                Text(pane.title)
                    .font(.title3.weight(.semibold))
                Text(pane.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A pane's page: its header, then its sections, in a grouped form.
struct SettingsPage<Pane: SettingsPane, Content: View>: View {
    let pane: Pane
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            SettingsPaneHeader(pane: pane)
            content
        }
        .formStyle(.grouped)
    }
}
