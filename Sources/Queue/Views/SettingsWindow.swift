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
    private var keyObserver: NSObjectProtocol?

    /// The global shortcut and whether it registered (set by AppDelegate at
    /// launch; HotKey returns nil when another app holds the combination).
    var globalShortcut: (combo: KeyCombo, registered: Bool) = (.togglePanel, true)

    /// Spec 1d: 500pt content width; height fits content (~560–620), scrolls if taller.
    private static let contentWidth: CGFloat = 500
    private static let maxContentHeight: CGFloat = 640
    private static let fallbackContentHeight: CGFloat = 590

    func show(state: AppState) {
        if window == nil {
            let window = makeWindow(state: state)
            window.center()
            // Back from System Settings (its "Open…" buttons): re-read what
            // may have changed there while the window stayed open.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.readSystemState() }
            }
            self.window = window
        }
        Self.readSystemState()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Notification permission and the login item live in System Settings,
    /// where the user can change them at any time.
    private static func readSystemState() {
        Notifier.shared.refreshAuthorizationStatus()
        LoginItem.shared.reload()
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
}

// MARK: - Content pane

struct SettingsContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var loginItem = LoginItem.shared

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
                toggleRow("Your PR fails CI, needs changes or has conflicts", isOn: $settings.notifyCIFailures)
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
                    Text("github.com · repo + read:org scopes")
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

    /// Reflects SMAppService, not a stored flag: removing Queue in System
    /// Settings → Login Items (or running a copy outside Applications) shows
    /// here. Hints stay on the row's line so the window keeps its height.
    private var launchAtLoginRow: some View {
        HStack(spacing: 8) {
            rowLabel("Launch at login")
            Spacer(minLength: 8)
            if let failure = loginItem.failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(ds.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(failure)
            } else if loginItem.status == .requiresApproval {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Allow in Login Items…")
                        .font(.system(size: 11))
                        .foregroundStyle(ds.link)
                }
                .buttonStyle(.plain)
                .help("macOS needs your OK in System Settings → General → Login Items before Queue can open at login.")
            }
            Toggle("", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(ds.toggleOn)
        }
        .padding(rowPadding)
    }

    /// The combination HotKey actually registered, or a warning when it
    /// couldn't (another app holds it).
    private var shortcutRow: some View {
        let shortcut = SettingsWindowController.shared.globalShortcut
        let label = shortcut.registered ? shortcut.combo.display : "\(shortcut.combo.display) · unavailable"
        return HStack(spacing: 8) {
            rowLabel("Global shortcut")
            Spacer(minLength: 8)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(shortcut.registered ? ds.textPrimary : ds.danger)
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .background(pal.kbdChipBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help(shortcut.registered
                      ? "Opens Queue from any app."
                      : "Another app already uses \(shortcut.combo.display), so it can't open Queue.")
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
}

// MARK: - Launch at login

/// Queue's login item as the system reports it (SMAppService). Read when
/// Settings opens or becomes key; never stored.
@MainActor
private final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// Why the last change didn't take; cleared by the next attempt.
    @Published private(set) var failure: String?

    /// requiresApproval is registered and only waiting for the user's OK,
    /// so the switch stays on (with a hint) rather than snapping back.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func reload() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
        // Fixed elsewhere (e.g. turned on in System Settings).
        if current == .enabled, failure != nil { failure = nil }
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = enabled ? Self.registerFailure(error) : "Couldn't turn off — \(error.localizedDescription)"
        }
        reload()
    }

    /// Registering fails for a copy macOS won't keep as a login item: run
    /// from a disk image or Downloads (translocated), or an unbundled build.
    private static func registerFailure(_ error: Error) -> String {
        let bundle = Bundle.main
        let installed = bundle.bundleIdentifier != nil && bundle.bundlePath.contains("/Applications/")
        return installed ? "Couldn't turn on — \(error.localizedDescription)" : "Move Queue to Applications to enable"
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
