import AppKit
import ServiceManagement
import SwiftUI

// Settings window (spec 1d — single pane, 500px wide).
// Native NSWindow shell + SwiftUI grouped-inset content. Follows system
// appearance: light per spec exactly, dark via DS equivalents.

// MARK: - Window controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Spec 1d: 500pt content width; height fits content (~560–620), scrolls if taller.
    private static let contentWidth: CGFloat = 500
    private static let maxContentHeight: CGFloat = 640
    private static let fallbackContentHeight: CGFloat = 590

    func show(state: AppState) {
        if window == nil {
            window = makeWindow(state: state)
            window?.center()
        }
        // The user may have just flipped notifications in System Settings.
        Notifier.shared.refreshAuthorizationStatus()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.close()
    }

    private func makeWindow(state: AppState) -> NSWindow {
        // Measure the natural content height with an unscrolled probe so the
        // window fits the pane; the real content stays in a ScrollView in case
        // it ever grows taller than the clamp.
        let probe = NSHostingView(
            rootView: SettingsContentView(state: state)
                .environmentObject(state)
                .frame(width: Self.contentWidth)
        )
        probe.layoutSubtreeIfNeeded()
        let measured = probe.fittingSize.height
        let height = measured > 100 ? min(measured, Self.maxContentHeight) : Self.fallbackContentHeight

        let hosting = NSHostingView(
            rootView: SettingsView(state: state).environmentObject(state)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Queue Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        return window
    }
}

// MARK: - Root view

struct SettingsView: View {
    private let stateRef: AppState
    @Environment(\.colorScheme) private var scheme

    init(state: AppState) {
        self.stateRef = state
    }

    var body: some View {
        ScrollView {
            SettingsContentView(state: stateRef)
        }
        .frame(width: 500)
        .background(SettingsPalette(scheme).windowBG)
    }
}

// MARK: - Palette (spec 1d light values; dark via DS equivalents)

private struct SettingsPalette {
    let dark: Bool
    let ds: DS

    init(_ scheme: ColorScheme) {
        dark = scheme == .dark
        ds = DS(scheme)
    }

    var windowBG: Color { dark ? Color(hex: 0x1E1F24) : Color(hex: 0xF2F2F5) }
    var cardBG: Color { dark ? Color.white.opacity(0.055) : .white }
    var cardBorder: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    var hairline: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var caption: Color { dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45) }
    var kbdChipBG: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06) }
    var segmentContainer: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06) }
    var segmentSelected: Color { dark ? Color.white.opacity(0.25) : .white }
    var segmentText: Color { dark ? Color.white.opacity(0.6) : Color.black.opacity(0.5) }
    var chipText: Color { dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45) }
    var chipBG: Color { dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05) }
}

// MARK: - Content pane

struct SettingsContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @State private var orgDraft: String = ""
    @ObservedObject private var notifier = Notifier.shared

    init(state: AppState) {
        _settings = ObservedObject(wrappedValue: state.settings)
    }

    private static let refreshOptions: [(interval: TimeInterval, label: String)] = [
        (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (900, "15 minutes"),
    ]

    private var pal: SettingsPalette { SettingsPalette(scheme) }
    private var ds: DS { DS(scheme) }
    private let rowPadding = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)

    private var username: String {
        if case .signedIn(let name) = state.auth { return name }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountCard
            group("GENERAL") {
                launchAtLoginRow
                hairline
                shortcutRow
                hairline
                refreshRow
            }
            group("NOTIFICATIONS") {
                if notifier.deniedInSystemSettings {
                    notificationsDeniedRow
                    hairline
                }
                toggleRow("New review request", isOn: $settings.notifyReviewRequests)
                hairline
                toggleRow("New mention", isOn: $settings.notifyMentions)
                hairline
                toggleRow("CI fails on your PR", isOn: $settings.notifyCIFailures)
                hairline
                toggleRow("Your PR is ready to merge", isOn: $settings.notifyPRReady)
            }
            group("MENU BAR") {
                badgeRow
                hairline
                toggleRow("Red dot when CI fails on your PR", isOn: $settings.alertOnCIFail)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: settings.launchAtLogin) { _, enabled in
            // The SPM binary is unbundled in dev — never crash on failure.
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login \(enabled ? "register" : "unregister") failed: \(error)")
            }
        }
        .onChange(of: settings.refreshInterval) { _, _ in
            state.startRefreshTimer()
        }
        // Badge style and CI-fail alert change what the status icon shows —
        // re-render it immediately instead of waiting for the next poll.
        .onChange(of: settings.badgeStyle) { _, _ in
            state.onStateChange?()
        }
        .onChange(of: settings.alertOnCIFail) { _, _ in
            state.onStateChange?()
        }
        // Watched-repo changes rescope every fetch — refresh right away.
        .onChange(of: settings.watchedRepos) { _, _ in
            state.onStateChange?()
            Task { await state.refresh() }
        }
    }

    // MARK: Scaffolding

    private var hairline: some View {
        Rectangle().fill(pal.hairline).frame(height: 1)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(pal.caption)
            card { rows() }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(pal.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(pal.cardBorder, lineWidth: 1)
            )
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(ds.textPrimary)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            rowLabel(label)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(ds.toggleOn)
        }
        .padding(rowPadding)
    }

    // MARK: Account card (no caption)

    private var accountCard: some View {
        card {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(username)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ds.textPrimary)
                    Text("github.com · read + review scopes")
                        .font(.system(size: 11))
                        .foregroundStyle(ds.textMeta)
                }
                Spacer(minLength: 8)
                Button {
                    state.signOut()
                    SettingsWindowController.shared.closeWindow()
                } label: {
                    Text("Sign out")
                        .font(.system(size: 12))
                        .foregroundStyle(ds.link)
                }
                .buttonStyle(.plain)
            }
            .padding(rowPadding)
        }
    }

    private var avatar: some View {
        let user = UserRef(login: username)
        return Circle()
            .fill(user.avatarColor)
            .frame(width: 28, height: 28)
            .overlay(
                Text(user.initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: General rows

    private var launchAtLoginRow: some View {
        toggleRow("Launch at login", isOn: $settings.launchAtLogin)
    }

    private var shortcutRow: some View {
        HStack(spacing: 8) {
            rowLabel("Global shortcut")
            Spacer(minLength: 8)
            Text(settings.shortcutDisplay)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ds.textPrimary)
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .background(pal.kbdChipBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(rowPadding)
    }

    private var refreshRow: some View {
        HStack(spacing: 8) {
            rowLabel("Refresh every")
            Spacer(minLength: 8)
            Picker("", selection: $settings.refreshInterval) {
                ForEach(Self.refreshOptions, id: \.interval) { option in
                    Text(option.label).tag(option.interval)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(rowPadding)
    }

    // MARK: Menu bar rows

    private var badgeRow: some View {
        HStack(spacing: 8) {
            rowLabel("Badge")
            Spacer(minLength: 8)
            BadgeSegmentedControl(selection: $settings.badgeStyle)
        }
        .padding(rowPadding)
    }

    // MARK: Notification rows

    private var notificationsDeniedRow: some View {
        HStack(spacing: 8) {
            Text("Notifications are off for Queue in System Settings.")
                .font(.system(size: 11.5))
                .foregroundStyle(ds.danger)
            Spacer(minLength: 8)
            Button("Open…") { notifier.openSystemSettings() }
                .controlSize(.small)
        }
        .padding(rowPadding)
    }

    // MARK: Watching rows

    private var organizationRow: some View {
        HStack(spacing: 8) {
            rowLabel("Organization")
            Spacer(minLength: 8)
            TextField("your repositories", text: $orgDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 170)
                .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                .background(pal.kbdChipBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onSubmit(commitOrganization)
        }
        .padding(rowPadding)
        .onAppear { orgDraft = settings.organization }
    }

    /// Commit the org, refetch the watchable repos, refresh data. Empty = the
    /// signed-in user's own repositories.
    private func commitOrganization() {
        let value = orgDraft.trimmingCharacters(in: .whitespaces)
        guard value != settings.organization else { return }
        settings.organization = value
        Task {
            await state.reloadAvailableRepos()
            await state.refresh()
        }
    }

    private var repoChipsRow: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(settings.availableRepos) { watchable in
                repoChip(watchable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(rowPadding)
    }

    private func repoChip(_ watchable: WatchableRepo) -> some View {
        let fullName = watchable.repo.fullName
        let selected = settings.watchedRepos.contains(fullName)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if selected {
                    settings.watchedRepos.remove(fullName)
                } else {
                    settings.watchedRepos.insert(fullName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(fullName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? ds.link : pal.chipText)
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .background(
                selected ? ds.link.opacity(0.10) : pal.chipBG,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Badge segmented control (custom per spec look)

private struct BadgeSegmentedControl: View {
    @Binding var selection: BadgeStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pal = SettingsPalette(scheme)
        let ds = DS(scheme)
        HStack(spacing: 2) {
            ForEach(BadgeStyle.allCases, id: \.self) { style in
                let selected = style == selection
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { selection = style }
                } label: {
                    Text(title(for: style))
                        .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? ds.textPrimary : pal.segmentText)
                        .padding(EdgeInsets(top: 2.5, leading: 10, bottom: 2.5, trailing: 10))
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(pal.segmentSelected)
                                    .shadow(color: .black.opacity(pal.dark ? 0.25 : 0.12), radius: 1.5, y: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(pal.segmentContainer, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func title(for style: BadgeStyle) -> String {
        switch style {
        case .count: return "Count"
        case .dot: return "Dot"
        case .off: return "Off"
        }
    }
}

// MARK: - Chip flow layout (wraps repo chips at the card width)

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width
            usedWidth = max(usedWidth, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
