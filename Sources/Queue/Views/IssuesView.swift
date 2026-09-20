import SwiftUI

// Issues tab (spec 1a "Issues tab", screenshot 03):
// assigned issues grouped by repo; circle-dot success icon; meta line
// "#4788 · assigned 2d ago" with the label chip right after; trailing age
// (amber when stale). Hover actions: snooze + open — no approve/merge.

struct IssuesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Removal/undo animation for rows leaving or re-entering the list.
    private static let listAnimation: Animation = .easeOut(duration: 0.15)

    /// `groupByRepo` returns tuples; ForEach needs stable identity.
    private struct RepoGroup: Identifiable {
        var repo: RepoRef
        var items: [AssignedIssue]
        var id: String { repo.fullName }
    }

    var body: some View {
        let ds = DS(scheme)
        let groups = groupByRepo(state.visibleIssues) { $0.repo }
            .map { RepoGroup(repo: $0.repo, items: $0.items) }

        VStack(spacing: 0) {
            if groups.isEmpty {
                EmptyStateLine(text: "No assigned issues")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            RepoGroupHeader(repo: group.repo, count: group.items.count)
                            ForEach(group.items) { issue in
                                row(for: issue, ds: ds)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if state.snoozedVisibleCount > 0 {
                SnoozedSummaryLine(count: state.snoozedVisibleCount) {
                    withAnimation(Self.listAnimation) { state.undoSnooze() }
                }
            }
            if let error = state.inlineError {
                InlineErrorLine(text: error)
            }
        }
    }

    private func row(for issue: AssignedIssue, ds: DS) -> some View {
        QueueRow(
            title: issue.title,
            meta: issue.meta,
            leading: {
                CircleDotIcon(color: ds.success, size: 15)
            },
            metaAccessory: {
                if let label = issue.label {
                    LabelChipView(label: label)
                }
            },
            trailing: {
                AgeText(age: issue.age)
            },
            actions: {
                IconActionButton(systemName: "clock", help: "Snooze until 9 AM tomorrow") {
                    withAnimation(Self.listAnimation) { state.snooze(id: issue.id) }
                }
                IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub") {
                    state.open(issue.url)
                }
            }
        )
    }
}
