import AppKit
import SwiftUI

// "My PRs" tab (spec 1a): the user's open PRs grouped by repo. Leading CI
// status icon (check / X / pulsing amber dot), title + "#n · branch" meta,
// trailing status pill. Hover reveals Merge (when ready) / Re-run (when
// failing) / "⌥ Copy branch" (always) / snooze / open.

struct MyPRsView: View {
    @EnvironmentObject var state: AppState

    private struct RepoGroup: Identifiable {
        var repo: RepoRef
        var items: [MyPR]
        var id: String { repo.fullName }
    }

    var body: some View {
        let visible = state.visiblePRs
        Group {
            if visible.isEmpty {
                VStack(spacing: 0) {
                    EmptyStateLine(text: "No open PRs")
                    bottomLines
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let groups = groupByRepo(visible) { $0.repo }
                            .map { RepoGroup(repo: $0.repo, items: $0.items) }
                        ForEach(groups) { group in
                            RepoGroupHeader(repo: group.repo, count: group.items.count)
                            ForEach(group.items) { pr in
                                MyPRRowView(pr: pr)
                            }
                        }
                        bottomLines
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    @ViewBuilder private var bottomLines: some View {
        if let merged = state.mergedTitles.last {
            MergedSummaryLine(title: merged)
        }
        if state.snoozedVisibleCount > 0 {
            SnoozedSummaryLine(count: state.snoozedVisibleCount) {
                withAnimation(.easeOut(duration: 0.15)) { state.undoSnooze() }
            }
        }
        if let error = state.inlineError {
            InlineErrorLine(text: error)
        }
    }
}

// MARK: - Row

private struct MyPRRowView: View {
    @EnvironmentObject var state: AppState
    var pr: MyPR

    @State private var copied = false
    @State private var copyGeneration = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        QueueRow(
            title: pr.title,
            meta: pr.meta,
            leading: { statusIcon(ds) },
            trailing: { StatusPillView(text: pr.pillText, kind: pr.pillKind) },
            actions: { actionCluster(ds) }
        )
    }

    /// ✓ success / ✕ danger / 9px pulsing attention dot (spec "My PRs tab").
    @ViewBuilder private func statusIcon(_ ds: DS) -> some View {
        switch pr.ci {
        case .passing:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ds.success)
        case .failing:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ds.danger)
        case .running:
            PulsingDot(color: ds.attention, size: 9)
        }
    }

    @ViewBuilder private func actionCluster(_ ds: DS) -> some View {
        if pr.isReady {
            TextActionButton(label: "Merge", color: ds.merge, background: ds.merge.opacity(0.14)) {
                withAnimation(.easeOut(duration: 0.15)) { state.merge(pr) }
            }
        }
        if pr.isFailing {
            TextActionButton(label: "Re-run", color: ds.attention, background: ds.attention.opacity(0.14)) {
                withAnimation(.easeOut(duration: 0.15)) { state.rerunChecks(pr) }
            }
        }
        // Spec: "⌥ Copy branch … always" — an unconditional cluster member
        // ("⌥" is literal label text), white 0.65 on white 0.10 dark / black
        // equivalents light — not covered by Theme.
        TextActionButton(
            label: copied ? "Copied" : "⌥ Copy branch",
            color: ds.dark ? Color.white.opacity(0.65) : Color.black.opacity(0.65),
            background: ds.dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
            action: copyBranch
        )
        IconActionButton(systemName: "clock", help: "Snooze until 9 AM tomorrow") {
            withAnimation(.easeOut(duration: 0.15)) { state.snooze(id: pr.id) }
        }
        IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub") {
            state.open(pr.url)
        }
    }

    private func copyBranch() {
        state.copyBranch(pr)
        copyGeneration += 1
        let generation = copyGeneration
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard generation == copyGeneration else { return }
            withAnimation(.easeOut(duration: 0.12)) { copied = false }
        }
    }
}
