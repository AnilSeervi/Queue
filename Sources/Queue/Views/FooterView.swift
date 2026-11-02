import SwiftUI

/// Footer: "Up next" — the most useful next step (AppState.nextSteps:
/// feedback to address, something to merge, CI to fix, a reviewer to nudge,
/// a quick review…), clickable to open on GitHub, with › stepping through the
/// rest. Right side: time-since-refresh + Settings gear.
struct FooterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            Rectangle().fill(ds.hairline).frame(height: 1)
            HStack(spacing: 10) {
                let steps = state.nextSteps
                if !steps.isEmpty {
                    let index = state.upNextIndex % steps.count
                    let step = steps[index]
                    Text("UP NEXT")
                        .font(DSFont.capsLabel())
                        .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                    Button {
                        state.openNextStep(step)
                    } label: {
                        HStack(spacing: 5) {
                            Text(step.action)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(ds.dark ? Color.white.opacity(0.78) : Color.black.opacity(0.75))
                                .lineLimit(1)
                                .fixedSize()
                            Text(step.title)
                                .font(DSFont.pill())
                                .foregroundStyle(ds.dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(step.age.display)
                                .font(DSFont.pill())
                                .foregroundStyle(step.age.isStale ? ds.attention : ds.textFaint)
                                .fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(step.action): \(step.title)\nOpen on GitHub")
                    if steps.count > 1 {
                        Button {
                            state.showNextStep()
                        } label: {
                            HStack(spacing: 2) {
                                Text("\(index + 1)/\(steps.count)")
                                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(ds.textFaint)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Next suggestion")
                        .accessibilityLabel("Next suggestion, \(index + 1) of \(steps.count)")
                    }
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
