import SwiftUI

// Inbox tab: review requests + mentions grouped by repo (spec 1a "Inbox tab",
// screenshot 01). Rows come from the shared RowKit scaffolding. Hovering a
// review request shows icons for Approve (optimistic — AppState removes the
// row immediately and restores on failure), Copy branch, Open in editor (on
// a worktree) and open on GitHub; the branch icons need the PR's head
// branch, so a PR from a fork Queue can't read has neither. Opening a
// mention (row click, ↗) or ✓ Done marks its thread read. At the end,
// "Done · N" opens what you've dealt with this week (DoneSection).

struct InboxView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// The Inbox is review requests + mentions; it's "clear" only once both loaded.
    private static let sections: Set<SnapshotSection> = [.reviews, .mentions]

    @Environment(\.rowPreview) private var preview

    var body: some View {
        let ds = DS(scheme)
        let entries = state.inbox

        VStack(spacing: 0) {
            if entries.isEmpty {
                EmptyListTab(tab: .inbox, sections: Self.sections, text: "Nothing needs you ✓") {
                    approvedLine
                    DoneSection(tab: .inbox, items: state.doneInbox)
                }
            } else {
                ListScrollView(tab: .inbox) {
                    ForEach(groupByRepo(entries, repo: { $0.repo }), id: \.repo) { group in
                        RepoGroupHeader(repo: group.repo, count: group.items.count)
                        ForEach(group.items) { entry in
                            row(for: entry, ds: ds)
                        }
                    }
                    approvedLine
                    DoneSection(tab: .inbox, items: state.doneInbox)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            TabStatusLines()
        }
    }

    @ViewBuilder private var approvedLine: some View {
        if state.approvedThisSession > 0 {
            ApprovedSummaryLine(count: state.approvedThisSession)
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
                pinned: pinned(entry, branch: request.branchRef),
                onOpen: { state.open(request.url) },
                leading: {
                    PRGlyph(color: request.age.isStale ? ds.attention : ds.success)
                },
                trailing: {
                    AgeText(age: request.age)
                },
                actions: {
                    // Approve green — spec: dark #7ee2a0, light ds.success.
                    IconActionButton(
                        systemName: "checkmark",
                        help: approveHelp(request),
                        accessibilityName: "Approve",
                        tint: ds.approve
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { state.approve(request) }
                    }
                    if let ref = request.branchRef {
                        CopyBranchButton(branch: ref.branch)
                        OpenInEditorButton(ref: ref)
                    }
                    OpenOnGitHubButton { state.open(request.url) }
                }
            )
        case .mention(let mention):
            QueueRow(
                title: mention.title,
                meta: mention.meta,
                pinned: pinned(entry, branch: nil),
                onOpen: { open(mention) },
                leading: {
                    if let author = mention.author {
                        AvatarView(user: author)
                    } else {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 11))
                            .foregroundStyle(ds.textFaint)
                    }
                },
                trailing: {
                    AgeText(age: mention.age)
                },
                actions: {
                    IconActionButton(systemName: "checkmark", help: "Done — mark as read") {
                        withAnimation(.easeOut(duration: 0.15)) { state.markRead(mention) }
                    }
                    OpenOnGitHubButton { open(mention) }
                }
            )
        }
    }

    /// Names the commit the approval is pinned to, when known.
    private func approveHelp(_ request: ReviewRequest) -> String {
        guard let sha = request.headSHA else { return "Approve this pull request" }
        return "Approve at commit \(sha.prefix(7))"
    }

    /// The actions stay up while the branch opens in the editor (and in
    /// the Snapshotter's hovered rows).
    private func pinned(_ entry: InboxEntry, branch: BranchRef?) -> Bool {
        if preview.hovered.contains(entry.id) { return true }
        guard let branch else { return false }
        return state.editorStep(for: branch) != nil || preview.busy.contains(AppState.editorKey(branch))
    }

    /// Opening a mention deals with it: the thread is marked read too.
    private func open(_ mention: Mention) {
        state.open(mention.url)
        state.markRead(mention)
    }
}
