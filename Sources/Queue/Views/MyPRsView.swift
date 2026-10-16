import AppKit
import SwiftUI

// "My PRs" tab (spec 1a): the user's open PRs grouped by repo. Leading CI
// status icon (check / X / pulsing amber dot / dash for no checks / faint dot
// when unknown), title + "#n · branch" meta, trailing status pill. The X opens
// the failing check. Hover reveals Merge (when ready; click twice) / Re-run
// (when failing Actions runs can be re-run) / "⌥ Copy branch" (always) /
// open. Rows arrive in MyPR.sortRank order within each repo and keep it
// here, so an optimistic change doesn't move a row under the pointer. At the
// end, "Done · N" opens your PRs merged this week (DoneSection).

struct MyPRsView: View {
    @EnvironmentObject var state: AppState

    private struct RepoGroup: Identifiable {
        var repo: RepoRef
        var items: [MyPR]
        var id: String { repo.fullName }
    }

    var body: some View {
        let prs = state.prs
        VStack(spacing: 0) {
            if prs.isEmpty {
                EmptyListTab(tab: .prs, sections: [.prs], text: "No open PRs") {
                    mergedLine
                    DoneSection(tab: .prs, items: state.donePRs)
                }
            } else {
                ListScrollView(tab: .prs) {
                    let groups = groupByRepo(prs) { $0.repo }
                        .map { RepoGroup(repo: $0.repo, items: $0.items) }
                    ForEach(groups) { group in
                        RepoGroupHeader(repo: group.repo, count: group.items.count)
                        ForEach(group.items) { pr in
                            MyPRRowView(pr: pr)
                        }
                    }
                    mergedLine
                    DoneSection(tab: .prs, items: state.donePRs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            TabStatusLines()
        }
    }

    @ViewBuilder private var mergedLine: some View {
        if let merged = state.mergedTitles.last {
            MergedSummaryLine(title: merged)
        }
    }
}

// MARK: - Row

private struct MyPRRowView: View {
    @EnvironmentObject var state: AppState
    var pr: MyPR

    @State private var copied = false
    @State private var copyGeneration = 0
    /// Two-step Merge (owner decision D2): the first click turns the button
    /// into "Squash & merge?" for `confirmWindow`; a second click merges.
    @State private var confirmingMerge = false
    @State private var confirmGeneration = 0
    @State private var confirmShownAt = Date.distantPast
    @Environment(\.colorScheme) private var scheme

    private static let confirmWindow: UInt64 = 3_000_000_000
    /// A double-click's second half lands sooner than this; it doesn't count
    /// as the confirmation.
    private static let confirmMinDelay: TimeInterval = 0.4

    var body: some View {
        let ds = DS(scheme)
        QueueRow(
            title: pr.title,
            meta: pr.meta,
            onOpen: { state.open(pr.url) },
            leading: { statusIcon(ds) },
            trailing: { StatusPillView(text: pr.pillText, kind: pr.pillKind) },
            actions: { actionCluster(ds) }
        )
    }

    /// ✓ success / ✕ danger (opens the failing check) / 9px pulsing attention
    /// dot / neutral dash for no checks / faint dot when CI is unknown.
    @ViewBuilder private func statusIcon(_ ds: DS) -> some View {
        switch pr.ci {
        case .passing:
            symbol("checkmark", ds.success)
                .help("Checks passed")
        case .failing:
            FailingCheckButton(pr: pr)
        case .running:
            PulsingDot(color: ds.attention, size: 9)
                .help("Checks running")
        case .none:
            symbol("minus", ds.textFaint)
                .help("No checks on this commit")
        case .unknown:
            Circle()
                .fill(ds.textGroupCount)
                .frame(width: 5, height: 5)
                .help("CI status unavailable — checked again on the next refresh")
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
    }

    @ViewBuilder private func actionCluster(_ ds: DS) -> some View {
        if pr.canMerge, let method = pr.mergeMethod {
            TextActionButton(
                label: confirmingMerge ? method.confirmLabel : "Merge",
                color: ds.merge,
                background: ds.merge.opacity(confirmingMerge ? 0.28 : 0.14),
                help: confirmingMerge
                    ? "Click again to merge #\(pr.number) (\(Self.describe(method).lowercased()))"
                    : "\(Self.describe(method)) — click, then confirm",
                action: { mergeTapped() }
            )
            // The cluster goes away when the pointer leaves the row; so does
            // a pending confirmation.
            .onDisappear(perform: cancelMergeConfirmation)
        }
        if pr.canRerun {
            TextActionButton(
                label: "Re-run",
                color: ds.attention,
                background: ds.attention.opacity(0.14),
                help: pr.failedRunIDs.count == 1
                    ? "Re-run the failed jobs"
                    : "Re-run the failed jobs in \(pr.failedRunIDs.count) workflow runs"
            ) {
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
            help: "Copy \(pr.branch)",
            action: copyBranch
        )
        IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub") {
            state.open(pr.url)
        }
    }

    private static func describe(_ method: MergeMethod) -> String {
        switch method {
        case .merge: return "Merge with a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    private func mergeTapped() {
        if confirmingMerge {
            guard Date().timeIntervalSince(confirmShownAt) >= Self.confirmMinDelay else { return }
            cancelMergeConfirmation()
            withAnimation(.easeOut(duration: 0.15)) { state.merge(pr) }
            return
        }
        confirmGeneration += 1
        let generation = confirmGeneration
        confirmShownAt = Date()
        withAnimation(.easeOut(duration: 0.12)) { confirmingMerge = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.confirmWindow)
            guard generation == confirmGeneration else { return }
            withAnimation(.easeOut(duration: 0.12)) { confirmingMerge = false }
        }
    }

    private func cancelMergeConfirmation() {
        guard confirmingMerge else { return }
        confirmGeneration += 1
        confirmingMerge = false
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

/// The failing-CI ✕: one click to the first failing check's log, with every
/// failure in the tooltip. It sits outside the hover cluster, so it stays
/// clickable while the row is hovered.
private struct FailingCheckButton: View {
    @EnvironmentObject var state: AppState
    var pr: MyPR

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        let summary = pr.failingCheckSummary ?? pr.pillText
        let mark = Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ds.danger)
        if let url = pr.failingCheckURL {
            Button { state.open(url) } label: {
                // 21pt target centered on the 15pt slot (it may overhang).
                mark
                    .frame(width: 21, height: 21)
                    .background(
                        hovered ? ds.danger.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("\(summary)\nClick to open the failing check")
            // The bare xmark would be read as "Close".
            .accessibilityLabel("Open failing check")
            .accessibilityHint(summary)
        } else {
            mark.help(summary)
                .accessibilityLabel("CI failing: \(summary)")
        }
    }
}
