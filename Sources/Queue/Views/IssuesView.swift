import SwiftUI

// Issues tab (spec 1a "Issues tab", screenshot 03):
// assigned issues grouped by repo; circle-dot success icon; meta line
// "#4788 · assigned 2d ago" with the label chip right after; trailing age
// (amber when stale). Click a row to open it. Hover action: open — no
// approve/merge.

struct IssuesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// `groupByRepo` returns tuples; ForEach needs stable identity.
    private struct RepoGroup: Identifiable {
        var repo: RepoRef
        var items: [AssignedIssue]
        var id: String { repo.fullName }
    }

    var body: some View {
        let ds = DS(scheme)
        let groups = groupByRepo(state.issues) { $0.repo }
            .map { RepoGroup(repo: $0.repo, items: $0.items) }

        VStack(spacing: 0) {
            if groups.isEmpty {
                TabEmptyState(sections: [.issues], text: "No assigned issues")
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
            TabStatusLines()
        }
    }

    private func row(for issue: AssignedIssue, ds: DS) -> some View {
        QueueRow(
            title: issue.title,
            meta: issue.meta,
            onOpen: { state.open(issue.url) },
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
                IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub") {
                    state.open(issue.url)
                }
            }
        )
    }
}
