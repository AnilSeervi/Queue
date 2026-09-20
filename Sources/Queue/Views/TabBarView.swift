import SwiftUI

/// Panel tab bar: Inbox · My PRs · Issues · Stats + snooze-all button (spec 1a §1).
struct TabBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, count: state.count(for: tab), isActive: state.activeTab == tab) {
                        state.activeTab = tab
                    }
                }
                Spacer(minLength: 0)
                Button {
                    state.snoozeAll()
                } label: {
                    SnoozeClockIcon(color: ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45), size: 14)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Snooze all until tomorrow")
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 8, trailing: 10))
            Rectangle().fill(ds.hairline).frame(height: 1)
        }
    }
}

private struct TabButton: View {
    var tab: PanelTab
    var count: Int
    var isActive: Bool
    var action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Button(action: action) {
            HStack(spacing: 5) {
                Text(tab.title)
                    .font(DSFont.tab())
                    // Spec 1a: active tab text is pure #fff in dark (distinct
                    // from the #f5f5f7 row-title primary); light keeps primary.
                    .foregroundStyle(isActive ? (ds.dark ? Color.white : ds.textPrimary) : ds.textSecondary)
                if count > 0 {
                    Text("\(count)")
                        .font(DSFont.chipCount())
                        .foregroundStyle(tab == .inbox
                                         ? ds.attentionBadgeText
                                         : (ds.dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6)))
                        .padding(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .background(ds.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            .background(
                isActive ? ds.controlActive : (hovered ? ds.control : .clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
