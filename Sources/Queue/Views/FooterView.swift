import SwiftUI

/// Footer: "Up next" — the oldest item that needs you (review requests,
/// mentions, and your PRs with failing CI, changes requested or conflicts),
/// clickable to open on GitHub (replaces the spec's per-repo CI strip: zero
/// setup, serves the triage loop directly). Right side: time-since-refresh +
/// Settings gear.
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
                        open(next.url)
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
                    .help("\(next.title)\nOpen on GitHub")
                } else {
                    // Not "All clear" until the badge's sections have loaded.
                    Text(state.hasLoaded ? "All clear ✓" : TabEmptyState.notLoadedText(state))
                        .font(DSFont.pill())
                        .foregroundStyle(ds.textFaint)
                }
                Spacer(minLength: 8)
                RefreshLabel(lastRefreshedAt: state.lastRefreshedAt, isRefreshing: state.isRefreshing) {
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

    /// Opening a mention from here marks it read, as its row does.
    private func open(_ url: URL) {
        state.open(url)
        for case .mention(let mention) in state.inbox where mention.url == url {
            state.markRead(mention)
            break
        }
    }
}

/// "↻ 30s" — time since last refresh, ticking; click = manual refresh.
/// Dimmed and disabled while a refresh is running.
private struct RefreshLabel: View {
    var lastRefreshedAt: Date?
    var isRefreshing: Bool
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
                .opacity(isRefreshing ? 0.5 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(isRefreshing ? "Refreshing…" : "Refresh now")
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
