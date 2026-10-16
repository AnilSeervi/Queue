import SwiftUI

// Shared list-row scaffolding used by Inbox / My PRs / Issues so every tab
// renders identically (spec 1a "List row", "Repo group header", hover actions).

// MARK: - Repo group header

struct RepoGroupHeader: View {
    var repo: RepoRef
    var count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        HStack(spacing: 6) {
            Text(repo.fullName)
                .font(DSFont.metaMono())
                .foregroundStyle(ds.textGroupHeader)
            Text("\(count)")
                .font(.system(size: 10.5))
                .foregroundStyle(ds.textGroupCount)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 3, trailing: 14))
    }
}

// MARK: - Row

/// List row: leading 15px icon slot, title + meta, trailing slot (age/pill),
/// hover reveals action cluster over a horizontal fade; row bg lightens.
/// `pinned` shows the cluster without the pointer (a branch opening in the
/// editor keeps its spinner in view). A click anywhere outside the row's
/// buttons calls `onOpen`.
struct QueueRow<Leading: View, TitleAccessory: View, MetaAccessory: View, Trailing: View, Actions: View>: View {
    @ViewBuilder var leading: () -> Leading
    var title: String
    @ViewBuilder var titleAccessory: () -> TitleAccessory
    var meta: String
    @ViewBuilder var metaAccessory: () -> MetaAccessory
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var actions: () -> Actions
    var pinned: Bool
    var onOpen: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    init(
        title: String,
        meta: String,
        pinned: Bool = false,
        onOpen: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder metaAccessory: @escaping () -> MetaAccessory = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.meta = meta
        self.pinned = pinned
        self.onOpen = onOpen
        self.leading = leading
        self.titleAccessory = titleAccessory
        self.metaAccessory = metaAccessory
        self.trailing = trailing
        self.actions = actions
    }

    var body: some View {
        let ds = DS(scheme)
        let active = hovered || pinned
        HStack(alignment: .center, spacing: 10) {
            leading()
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // One line, and the hover cluster covers the end of it:
                    // the tooltip carries the full text.
                    Text(title)
                        .font(DSFont.rowTitle())
                        .foregroundStyle(ds.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                    titleAccessory()
                }
                HStack(spacing: 6) {
                    Text(meta)
                        .font(DSFont.meta())
                        .foregroundStyle(ds.textMeta)
                        .lineLimit(1)
                        .help(meta)
                    metaAccessory()
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
        .frame(minHeight: 30)
        .background(active ? ds.rowHover : .clear)
        .overlay(alignment: .trailing) {
            if active {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [ds.hoverFadeBase.opacity(0), ds.hoverFadeBase],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 28)
                    // Full row height, like the fade beside it.
                    HStack(spacing: 6) { actions() }
                        .padding(.trailing, 8)
                        .frame(maxHeight: .infinity)
                        .background(ds.hoverFadeBase)
                }
                .transition(.opacity)
            }
        }
        // Buttons (leading icon, hover cluster) keep their own clicks — a
        // child's gesture wins over this one, so nothing fires twice. The
        // rest of the row, the cluster's backdrop included, opens it.
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
    }
}

// MARK: - Buttons

/// 24px square icon button: every hover action (Approve, Merge, Re-run,
/// Copy branch, Open in editor, ✓ Done, open on GitHub). `tint` colors the
/// symbol and its backdrop (approve green, merge purple, re-run amber); nil
/// is the neutral gray. `label` widens it into a pill with the text after
/// the symbol (Merge asking to confirm). `isBusy` swaps the symbol for a
/// spinner; the button still takes the click (and its owner ignores it), so
/// the click can't fall through to the row and open it.
struct IconActionButton: View {
    var systemName: String
    /// Tooltip.
    var help: String
    /// What VoiceOver calls it; nil = `help`.
    var accessibilityName: String? = nil
    var tint: Color? = nil
    var label: String? = nil
    var isBusy = false
    var action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        let fg = tint ?? (ds.dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
        let bg: Color = {
            if let tint { return tint.opacity(label != nil ? 0.28 : hovered ? 0.24 : 0.14) }
            return hovered ? ds.controlActive : ds.control
        }()
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: tint == nil ? .medium : .semibold))
                }
                if let label {
                    Text(label)
                        .font(DSFont.button())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, label == nil ? 0 : 8)
            .frame(minWidth: 24, minHeight: 24)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        // VoiceOver names the button by what it does, not by its symbol.
        .accessibilityLabel(accessibilityName ?? help)
    }
}

/// Copy branch: puts the branch name on the clipboard, and shows a
/// checkmark for a second to say so.
struct CopyBranchButton: View {
    @EnvironmentObject var state: AppState
    var branch: String

    @State private var copied = false
    @State private var generation = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        IconActionButton(
            systemName: copied ? "checkmark" : "doc.on.doc",
            help: copied ? "Copied \(branch)" : "Copy branch \(branch)",
            accessibilityName: copied ? "Copied" : "Copy branch name",
            tint: copied ? DS(scheme).success : nil,
            action: copy
        )
    }

    private func copy() {
        state.copyBranch(branch)
        generation += 1
        let current = generation
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard current == generation else { return }
            withAnimation(.easeOut(duration: 0.12)) { copied = false }
        }
    }
}

/// Open in editor: the PR's branch, on a worktree beside your clone, in the
/// editor chosen in Settings (AppState.openInEditor). Spins while Queue
/// clones or fetches; the tooltip says which step it's on.
struct OpenInEditorButton: View {
    @EnvironmentObject var state: AppState
    var ref: BranchRef
    @Environment(\.rowPreview) private var preview

    var body: some View {
        let step = state.editorStep(for: ref)
            ?? (preview.busy.contains(AppState.editorKey(ref)) ? WorkspaceStep.fetching(branch: ref.branch).label : nil)
        let editor = EditorCatalog.preferred(state.settings.editorBundleID)?.name ?? "your editor"
        IconActionButton(
            systemName: "chevron.left.forwardslash.chevron.right",
            help: step ?? "Open in \(editor) (worktree)",
            accessibilityName: step ?? "Open in \(editor) on a worktree",
            isBusy: step != nil
        ) {
            state.openInEditor(ref)
        }
    }
}

/// Open on GitHub (↗).
struct OpenOnGitHubButton: View {
    var action: () -> Void

    var body: some View {
        IconActionButton(systemName: "arrow.up.right", help: "Open on GitHub", action: action)
    }
}

// MARK: - Snapshot preview

/// Snapshotter only: rows drawn as if the pointer were on them (their
/// actions showing), by row id; My PRs rows with Merge asking to confirm;
/// branches (AppState.editorKey) shown opening in the editor.
struct RowPreview {
    var hovered: Set<String> = []
    var confirmingMerge: Set<String> = []
    var busy: Set<String> = []
}

private struct RowPreviewKey: EnvironmentKey {
    static let defaultValue = RowPreview()
}

extension EnvironmentValues {
    var rowPreview: RowPreview {
        get { self[RowPreviewKey.self] }
        set { self[RowPreviewKey.self] = newValue }
    }
}

// MARK: - Pills & chips

struct StatusPillView: View {
    var text: String
    var kind: PillKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        let (fg, bg): (Color, Color) = {
            switch kind {
            case .neutral:
                return (ds.dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55),
                        ds.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            case .ready: return (ds.success, ds.success.opacity(0.12))
            case .failed: return (ds.danger, ds.danger.opacity(0.12))
            case .running: return (ds.attention, ds.attention.opacity(0.12))
            }
        }()
        Text(text)
            .font(DSFont.pill())
            .foregroundStyle(fg)
            .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
            .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Issue label chip: 10px/600, 1px border in label color.
struct LabelChipView: View {
    var label: IssueLabel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = DS(scheme).issueLabelColor(label.name)
        Text(label.name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(color, lineWidth: 1))
    }
}

/// Trailing age text; amber when stale (≥3d). The tooltip has the date.
struct AgeText: View {
    var age: Age
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Text(age.display)
            .font(DSFont.pill())
            .foregroundStyle(age.isStale ? ds.attention : ds.textFaint)
            .help(age.date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// 15px circular avatar with initials.
struct AvatarView: View {
    var user: UserRef

    var body: some View {
        Circle()
            .fill(user.avatarColor)
            .frame(width: 15, height: 15)
            .overlay(
                Text(user.initials)
                    .font(DSFont.avatarInitials())
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Bottom summary / confirmation lines

/// Green check line: "n approved this session".
struct ApprovedSummaryLine: View {
    var count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
            Text("\(count) approved this session")
                .font(DSFont.meta())
        }
        // Spec 1a: "11px #7ee2a0" — the approve green, not the general success token.
        .foregroundStyle(ds.approve)
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }
}

/// Purple PR-glyph line: "Merged · <title>".
struct MergedSummaryLine: View {
    var title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        HStack(spacing: 6) {
            PRGlyph(color: ds.merge, size: 12, lineWidth: 1.4)
            Text("Merged · \(title)")
                .font(DSFont.meta())
                .foregroundStyle(ds.merge)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }
}

/// Inline error line: a failed action, or a refresh that failed and left
/// the last good data showing.
struct InlineErrorLine: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(DSFont.meta())
            .foregroundStyle(DS(scheme).danger)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .help(text)
    }
}

/// "Authorize this token for SSO" — GitHub left out (or refused) results
/// from an org that enforces SAML single sign-on. One quiet line above the
/// footer, linking to where the token is authorized.
struct SSONoticeLine: View {
    var notice: SSONotice
    var onOpen: (URL) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        let (text, link, url) = content
        VStack(spacing: 0) {
            Rectangle().fill(ds.hairline).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(ds.attention)
                Text(text)
                    .font(DSFont.meta())
                    .foregroundStyle(ds.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button { onOpen(url) } label: {
                    Text(link)
                        .font(DSFont.meta())
                        .underline()
                        .foregroundStyle(ds.dark ? Color.white.opacity(0.7) : Color.black.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
        }
        .help("Items from orgs that enforce SAML SSO are left out until this token is authorized for them.")
    }

    /// GitHub's header names orgs by numeric id (or not at all), so the line
    /// counts them rather than naming them.
    private var content: (text: String, link: String, url: URL) {
        switch notice {
        case .required(let authorizeURL):
            return ("An org requires SSO — this token isn't authorized ·", "Authorize", authorizeURL)
        case .partialResults(let orgs):
            let which = orgs.isEmpty
                ? "Some orgs are hidden"
                : "\(orgs.count) org\(orgs.count == 1 ? " is" : "s are") hidden"
            return ("\(which) — token not authorized for SSO ·", "Authorize", Self.credentialsPage)
        }
    }

    /// Where a token gets SSO access: classic tokens are authorized per
    /// token; device-flow sign-ins are an OAuth app grant.
    private static var credentialsPage: URL {
        let method = UserDefaults.standard.string(forKey: GitHubAuth.authMethodKey)
        return URL(string: method == "device"
                   ? "https://github.com/settings/applications"
                   : "https://github.com/settings/tokens")!
    }
}

/// Single centered muted line for empty tabs.
struct EmptyStateLine: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(DS(scheme).textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Empty-tab line that only claims "nothing here" once the tab's sections
/// have loaded; before that, "Loading…" (or, when the load failed, a
/// neutral line — the inline error under it says why).
struct TabEmptyState: View {
    @EnvironmentObject var state: AppState
    var sections: Set<SnapshotSection>
    var text: String

    var body: some View {
        EmptyStateLine(text: state.loadedSections.isSuperset(of: sections) ? text : Self.notLoadedText(state))
    }

    static func notLoadedText(_ state: AppState) -> String {
        state.isRefreshing || state.inlineError == nil ? "Loading…" : "Not loaded yet"
    }
}

/// A list tab with no open items: the empty-state line centered, with
/// `footer` (the confirmation line, the Done section) along the bottom.
/// When the footer outgrows the tab (an opened Done list), it all scrolls,
/// the line on top.
struct EmptyListTab<Footer: View>: View {
    var tab: PanelTab
    var sections: Set<SnapshotSection>
    var text: String
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                TabEmptyState(sections: sections, text: text)
                footer()
            }
            ListScrollView(tab: tab) {
                TabEmptyState(sections: sections, text: text)
                    .frame(height: 88)
                footer()
            }
        }
    }
}

/// A list tab's scroll view. Starts at `listScrollAnchor`, and opening the
/// tab's Done section scrolls it up into view: its row usually sits at the
/// bottom edge, the list it opens below the fold.
struct ListScrollView<Content: View>: View {
    @EnvironmentObject var state: AppState
    var tab: PanelTab
    @ViewBuilder var content: () -> Content
    @Environment(\.listScrollAnchor) private var scrollAnchor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.bottom, 6)
            }
            .defaultScrollAnchor(scrollAnchor)
            .onChange(of: state.expandedDone.contains(tab)) { _, opened in
                guard opened else { return }
                // After the rows have opened: until then the content isn't
                // tall enough to scroll to.
                DispatchQueue.main.asyncAfter(deadline: .now() + DoneSection.openDuration + 0.05) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(DoneSection.headerID, anchor: .top)
                    }
                }
            }
        }
    }
}

private struct ListScrollAnchorKey: EnvironmentKey {
    static let defaultValue: UnitPoint? = nil
}

extension EnvironmentValues {
    /// Where list tabs' scroll views start (nil: the top). The Snapshotter
    /// renders the opened Done sections scrolled to the end.
    var listScrollAnchor: UnitPoint? {
        get { self[ListScrollAnchorKey.self] }
        set { self[ListScrollAnchorKey.self] = newValue }
    }
}

// MARK: - Done section

/// The end of Inbox and My PRs: what you've dealt with in the last
/// `doneWindow`. One "Done · N" row (none at 0) that opens in place into
/// compact rows, newest first, each opening on GitHub. Open or closed is
/// remembered per tab until Queue quits.
struct DoneSection: View {
    @EnvironmentObject var state: AppState
    var tab: PanelTab
    var items: [DoneItem]
    @Environment(\.colorScheme) private var scheme

    /// ListScrollView scrolls here when the section opens.
    static let headerID = "done-header"
    static let openDuration: TimeInterval = 0.15

    var body: some View {
        if !items.isEmpty {
            let expanded = state.expandedDone.contains(tab)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(DS(scheme).hairline)
                    .frame(height: 1)
                    .padding(EdgeInsets(top: 6, leading: 14, bottom: 0, trailing: 14))
                DoneHeader(count: items.count, expanded: expanded) {
                    withAnimation(.easeOut(duration: Self.openDuration)) { state.toggleDone(tab) }
                }
                .id(Self.headerID)
                if expanded {
                    ForEach(items) { item in
                        DoneRow(item: item) { state.open(item.url) }
                    }
                }
            }
        }
    }
}

/// "› Done · 6": toggles the list under it.
private struct DoneHeader: View {
    var count: Int
    var expanded: Bool
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ds.textGroupHeader)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Text("Done")
                    .font(DSFont.sectionLabel())
                    .foregroundStyle(ds.textGroupHeader)
                Text("· \(count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ds.textGroupCount)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .background(hovered ? ds.rowHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(expanded ? "Hide what you've dealt with" : "What you've dealt with in the last 7 days")
        .accessibilityLabel("Done, \(count) in the last 7 days")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }
}

/// Compact Done row: outcome glyph, title, "repo#n · outcome", age. Quieter
/// than an open row; the whole row opens it on GitHub.
private struct DoneRow: View {
    var item: DoneItem
    var onOpen: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        let age = Age(date: item.doneAt)
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                DoneGlyph(outcome: item.outcome)
                    .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ds.textPrimary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.listMeta)
                        .font(DSFont.meta())
                        .foregroundStyle(ds.textFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(age.display)
                    .font(DSFont.pill())
                    .foregroundStyle(ds.textFaint)
            }
            .padding(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            .background(hovered ? ds.rowHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(item.title)\n\(item.listMeta) · \(item.doneAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityLabel("\(item.title), \(item.listMeta), \(age.display) ago")
        .accessibilityHint("Opens on GitHub")
    }
}

/// A Done row's leading glyph: what happened, a step quieter than the
/// open rows' icons.
private struct DoneGlyph: View {
    var outcome: DoneOutcome
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        switch outcome {
        case .approved: symbol("checkmark", ds.approve)
        case .commented: symbol("bubble.left", ds.textSecondary)
        case .changesRequested: symbol("xmark", ds.danger)
        case .cleared: symbol("checkmark", ds.textFaint)
        case .merged: PRGlyph(color: ds.merge.opacity(0.85), size: 13, lineWidth: 1.4)
        case .resolvedMerged: PRGlyph(color: ds.merge.opacity(0.6), size: 13, lineWidth: 1.4)
        case .resolvedClosed: symbol("xmark", ds.textFaint)
        case .requestRemoved: symbol("minus", ds.textFaint)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color.opacity(0.8))
    }
}

/// Status line pinned under a list tab's scroll view, so it's never below
/// the fold: the inline error.
struct TabStatusLines: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let error = state.inlineError {
            InlineErrorLine(text: error)
        }
    }
}
