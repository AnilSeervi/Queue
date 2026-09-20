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
struct QueueRow<Leading: View, TitleAccessory: View, MetaAccessory: View, Trailing: View, Actions: View>: View {
    @ViewBuilder var leading: () -> Leading
    var title: String
    @ViewBuilder var titleAccessory: () -> TitleAccessory
    var meta: String
    @ViewBuilder var metaAccessory: () -> MetaAccessory
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var actions: () -> Actions

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    init(
        title: String,
        meta: String,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder metaAccessory: @escaping () -> MetaAccessory = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.meta = meta
        self.leading = leading
        self.titleAccessory = titleAccessory
        self.metaAccessory = metaAccessory
        self.trailing = trailing
        self.actions = actions
    }

    var body: some View {
        let ds = DS(scheme)
        HStack(alignment: .center, spacing: 10) {
            leading()
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(DSFont.rowTitle())
                        .foregroundStyle(ds.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    titleAccessory()
                }
                HStack(spacing: 6) {
                    Text(meta)
                        .font(DSFont.meta())
                        .foregroundStyle(ds.textMeta)
                        .lineLimit(1)
                    metaAccessory()
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
        .frame(minHeight: 30)
        .background(hovered ? ds.rowHover : .clear)
        .overlay(alignment: .trailing) {
            if hovered {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [ds.hoverFadeBase.opacity(0), ds.hoverFadeBase],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 28)
                    HStack(spacing: 6) { actions() }
                        .padding(.trailing, 8)
                        .background(ds.hoverFadeBase)
                }
                .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
    }
}

// MARK: - Buttons

/// Text action button, e.g. Approve / Merge / Re-run / ⌥ Copy branch.
struct TextActionButton: View {
    var label: String
    var color: Color
    var background: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DSFont.button())
                .foregroundStyle(color)
                .padding(EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9))
                .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 24px square icon button (snooze, open-on-GitHub, tab bar snooze-all).
struct IconActionButton: View {
    var systemName: String?
    var help: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(ds.dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
            .frame(width: 24, height: 24)
            .background(ds.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
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

/// Trailing age text; amber when stale (≥3d).
struct AgeText: View {
    var age: Age
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Text(age.display)
            .font(DSFont.pill())
            .foregroundStyle(age.isStale ? ds.attention : ds.textFaint)
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

/// "Snoozed until 9 AM · n items · Undo", hairline top.
struct SnoozedSummaryLine: View {
    var count: Int
    var onUndo: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            Rectangle().fill(ds.hairline).frame(height: 1)
            HStack(spacing: 0) {
                Text("Snoozed until 9 AM · \(count) item\(count == 1 ? "" : "s") · ")
                    .font(DSFont.meta())
                    .foregroundStyle(ds.dark ? Color.white.opacity(0.38) : Color.black.opacity(0.38))
                Button(action: onUndo) {
                    Text("Undo")
                        .font(DSFont.meta())
                        .underline()
                        .foregroundStyle(ds.dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        }
    }
}

/// Inline error line (restore-on-failure states).
struct InlineErrorLine: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(DSFont.meta())
            .foregroundStyle(DS(scheme).danger)
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
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
