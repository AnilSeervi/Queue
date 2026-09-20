import SwiftUI

// Inbox tab: review requests + mentions grouped by repo (spec 1a "Inbox tab",
// screenshot 01). Rows come from the shared RowKit scaffolding; approve/snooze
// are optimistic — AppState removes the row immediately and restores on failure.

struct InboxView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Approve button fg — spec: dark #7ee2a0, light ds.success.
    private var approveColor: Color {
        DS(scheme).approve
    }
    /// Approve button bg — dark rgba(126,226,160,0.14), light success @ 0.14.
    private var approveBackground: Color {
        approveColor.opacity(0.14)
    }

    var body: some View {
        let ds = DS(scheme)
        let entries = state.visibleInbox
        let hasSummaryLines = state.approvedThisSession > 0
            || state.snoozedVisibleCount > 0
            || state.inlineError != nil

        if entries.isEmpty && !hasSummaryLines {
            EmptyStateLine(text: "Nothing needs you ✓")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groupByRepo(entries, repo: { $0.repo }), id: \.repo) { group in
                        RepoGroupHeader(repo: group.repo, count: group.items.count)
                        ForEach(group.items) { entry in
                            row(for: entry, ds: ds)
                        }
                    }

                    if state.approvedThisSession > 0 {
                        ApprovedSummaryLine(count: state.approvedThisSession)
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
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for entry: InboxEntry, ds: DS) -> some View {
        switch entry {
        case .review(let request):
            QueueRow(
                title: request.title,
                meta: request.meta,
                leading: {
                    PRGlyph(color: request.age.isStale ? ds.attention : ds.success)
                },
                trailing: {
                    AgeText(age: request.age)
                },
                actions: {
                    TextActionButton(
                        label: "Approve",
                        color: approveColor,
                        background: approveBackground
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { state.approve(request) }
                    }
                    snoozeButton(id: request.id)
                    openButton(url: request.url)
                }
            )
        case .mention(let mention):
            QueueRow(
                title: mention.title,
                meta: mention.meta,
                leading: {
                    AvatarView(user: mention.author)
                },
                trailing: {
                    AgeText(age: mention.age)
                },
                actions: {
                    snoozeButton(id: mention.id)
                    openButton(url: mention.url)
                }
            )
        }
    }

    // MARK: Shared hover actions

    private func snoozeButton(id: String) -> some View {
        IconActionButton(systemName: "clock", help: "Snooze until tomorrow 9 AM") {
            withAnimation(.easeOut(duration: 0.15)) { state.snooze(id: id) }
        }
    }

    private func openButton(url: URL) -> some View {
        IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub") {
            state.open(url)
        }
    }
}
