import SwiftUI

/// Footer: "Up next" — the oldest item that needs you, clickable to open on
/// GitHub (replaces the spec's per-repo CI strip: zero setup, serves the
/// triage loop directly). Right side: time-since-refresh + Settings gear.
struct FooterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            Rectangle().fill(ds.hairline).frame(height: 1)
            HStack(spacing: 10) {
                if let next = state.upNext {
                    Text("UP NEXT")
                        .font(DSFont.capsLabel())
                        .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                    Button {
                        state.open(next.url)
                    } label: {
                        HStack(spacing: 5) {
                            Text(next.title)
                                .font(DSFont.pill())
                                .foregroundStyle(ds.dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(next.age.display)
                                .font(DSFont.pill())
                                .foregroundStyle(next.age.isStale ? ds.attention : ds.textFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open on GitHub")
                } else {
                    Text("All clear ✓")
                        .font(DSFont.pill())
                        .foregroundStyle(ds.textFaint)
                }
                Spacer(minLength: 8)
                RefreshLabel(lastRefreshedAt: state.lastRefreshedAt) {
                    Task { await state.refresh() }
                }
                Button {
                    state.openSettingsWindow?()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        }
    }
}

/// "↻ 30s" — time since last refresh, ticking; click = manual refresh.
private struct RefreshLabel: View {
    var lastRefreshedAt: Date?
    var onRefresh: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button(action: onRefresh) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                    Text(agoText(now: context.date))
                        .font(DSFont.pill())
                }
                .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    private func agoText(now: Date) -> String {
        guard let lastRefreshedAt else { return "—" }
        let s = Int(now.timeIntervalSince(lastRefreshedAt))
        if s < 60 { return "\(max(s, 0))s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }
}
