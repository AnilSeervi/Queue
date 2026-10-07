import AppKit
import SwiftUI

// MARK: - Data source abstraction

struct Snapshot {
    var inbox: [InboxEntry]
    var prs: [MyPR]
    var issues: [AssignedIssue]
    var stats: StatsData?
    var repoCI: [RepoCIStatus]
}

/// Implemented by MockDataSource (demo) and GitHubDataSource (live).
protocol QueueDataSource {
    func refresh() async throws -> Snapshot
    func approve(_ request: ReviewRequest) async throws
    func merge(_ pr: MyPR) async throws
    func rerunChecks(_ pr: MyPR) async throws
}

/// Auth boundary between onboarding UI and the GitHub integration.
protocol AuthProvider {
    /// Begin the OAuth device flow; returns the user code + verification URL to display.
    func startDeviceFlow() async throws -> DeviceFlowInfo
    /// Poll until the user authorizes; stores the token (Keychain) and returns the login.
    func waitForSignIn() async throws -> String
    /// Repos in the configured org the user can watch (onboarding step 2).
    func fetchWatchableRepos() async throws -> [WatchableRepo]
    /// Validate a personal access token, store it (Keychain), return the login.
    func signIn(withToken token: String) async throws -> String
    /// Clear stored credentials (Keychain token, cached login).
    func signOut()
}

extension AuthProvider {
    func signOut() {}
    func signIn(withToken token: String) async throws -> String {
        throw GitHubError.api("Token sign-in isn't available.")
    }
}

// MARK: - Settings

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var badgeStyle: BadgeStyle { didSet { defaults.set(badgeStyle.rawValue, forKey: "badgeStyle") } }
    @Published var alertOnCIFail: Bool { didSet { defaults.set(alertOnCIFail, forKey: "alertOnCIFail") } }
    @Published var showCIStrip: Bool { didSet { defaults.set(showCIStrip, forKey: "showCIStrip") } }
    @Published var organization: String { didSet { defaults.set(organization, forKey: "organization") } }
    @Published var watchedRepos: Set<String> { didSet { defaults.set(Array(watchedRepos), forKey: "watchedRepos") } }
    @Published var onlyNeedsMe: Bool { didSet { defaults.set(onlyNeedsMe, forKey: "onlyNeedsMe") } }
    // Notifications, one toggle per event type (all on by default).
    @Published var notifyReviewRequests: Bool { didSet { defaults.set(notifyReviewRequests, forKey: "notifyReviewRequests") } }
    @Published var notifyMentions: Bool { didSet { defaults.set(notifyMentions, forKey: "notifyMentions") } }
    @Published var notifyCIFailures: Bool { didSet { defaults.set(notifyCIFailures, forKey: "notifyCIFailures") } }
    @Published var notifyPRReady: Bool { didSet { defaults.set(notifyPRReady, forKey: "notifyPRReady") } }
    /// Display string for the global shortcut chip; capture UI updates this.
    @Published var shortcutDisplay: String { didSet { defaults.set(shortcutDisplay, forKey: "shortcutDisplay") } }

    /// Repos available to watch (from the org); refreshed by the data layer.
    @Published var availableRepos: [WatchableRepo] = MockData.watchableRepos

    init() {
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 120
        badgeStyle = BadgeStyle(rawValue: defaults.string(forKey: "badgeStyle") ?? "") ?? .count
        alertOnCIFail = defaults.object(forKey: "alertOnCIFail") as? Bool ?? true
        showCIStrip = defaults.object(forKey: "showCIStrip") as? Bool ?? true
        // Empty organization = "your repositories" (the signed-in user's own).
        organization = defaults.string(forKey: "organization") ?? ""
        watchedRepos = Set(defaults.stringArray(forKey: "watchedRepos") ?? [])
        onlyNeedsMe = defaults.object(forKey: "onlyNeedsMe") as? Bool ?? false
        notifyReviewRequests = defaults.object(forKey: "notifyReviewRequests") as? Bool ?? true
        notifyMentions = defaults.object(forKey: "notifyMentions") as? Bool ?? true
        notifyCIFailures = defaults.object(forKey: "notifyCIFailures") as? Bool ?? true
        notifyPRReady = defaults.object(forKey: "notifyPRReady") as? Bool ?? true
        shortcutDisplay = defaults.string(forKey: "shortcutDisplay") ?? "⌥ ⇧ G"

        // Migrate away the demo-fixture defaults shipped before the org was
        // configurable — they scoped every live search to repos nobody has.
        if organization == "acme" { organization = "" }
        if !watchedRepos.isEmpty, watchedRepos.allSatisfy({ $0.hasPrefix("acme/") }) {
            watchedRepos = []
        }
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore
    var dataSource: QueueDataSource

    // Data
    @Published var inbox: [InboxEntry] = []
    @Published var prs: [MyPR] = []
    @Published var issues: [AssignedIssue] = []
    @Published var stats: StatsData?
    @Published var repoCI: [RepoCIStatus] = []
    @Published var lastRefreshedAt: Date?
    @Published var isRefreshing = false

    // UI
    @Published var activeTab: PanelTab {
        didSet { UserDefaults.standard.set(activeTab.rawValue, forKey: "activeTab") }
    }
    @Published var auth: AuthState

    // Session mutations (spec "State Management": session approvedIds/mergedIds).
    // refresh() filters re-fetched rows against these so acted-on items don't
    // resurrect while the summary lines still show them as done.
    @Published var approvedIds: Set<String> = []
    @Published var mergedIds: Set<String> = []
    /// Titles for the "Merged · <title>" confirmation line, in merge order.
    @Published var mergedTitles: [String] = []
    @Published var inlineError: String?

    var approvedThisSession: Int { approvedIds.count }

    // Snooze: item id -> wake time. Persisted.
    @Published var snoozed: [String: Date] {
        didSet { persistSnoozed() }
    }
    /// Wake time of the last "snooze all" gesture; the Snoozed/DND icon state
    /// derives from this so it expires with the snooze (9 AM next day).
    @Published var snoozeAllUntil: Date? {
        didSet { UserDefaults.standard.set(snoozeAllUntil, forKey: "snoozeAllUntil") }
    }
    var snoozeAllActive: Bool {
        guard let until = snoozeAllUntil else { return false }
        return until > Date()
    }

    /// Ticks when the status icon needs re-render; observed by StatusItemController.
    var onStateChange: (() -> Void)?
    /// Wired by AppDelegate: opens the Settings window (footer gear).
    var openSettingsWindow: (() -> Void)?
    /// Wired by AppDelegate: closes the panel (used after deep-linking out).
    var closePanel: (() -> Void)?

    var authProvider: AuthProvider?
    private var pendingUsername: String?
    /// The in-flight device-flow task, cancelled when switching to token entry.
    private var signInTask: Task<Void, Never>?

    // Token sign-in (alternative to the device flow).
    @Published var tokenEntryActive = false
    @Published var isSigningInWithToken = false
    @Published var tokenError: String?
    private var refreshTimer: Timer?
    private var rerunResetTasks: [String: Task<Void, Never>] = [:]

    static var isDemo: Bool { ProcessInfo.processInfo.environment["QUEUE_DEMO"] == "1" }

    init(settings: SettingsStore, dataSource: QueueDataSource, auth: AuthState) {
        self.settings = settings
        self.dataSource = dataSource
        self.auth = auth
        self.activeTab = PanelTab(rawValue: UserDefaults.standard.string(forKey: "activeTab") ?? "") ?? .inbox
        if let data = UserDefaults.standard.data(forKey: "snoozed"),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Drop already-woken entries.
            self.snoozed = decoded.filter { $0.value > Date() }
        } else {
            self.snoozed = [:]
        }
        if let until = UserDefaults.standard.object(forKey: "snoozeAllUntil") as? Date, until > Date() {
            self.snoozeAllUntil = until
        }
    }

    private func persistSnoozed() {
        if let data = try? JSONEncoder().encode(snoozed) {
            UserDefaults.standard.set(data, forKey: "snoozed")
        }
        onStateChange?()
    }

    // MARK: Visible lists (snooze-filtered)

    private func isSnoozed(_ id: String) -> Bool {
        guard let wake = snoozed[id] else { return false }
        return wake > Date()
    }

    var visibleInbox: [InboxEntry] { inbox.filter { !isSnoozed($0.id) } }
    var visiblePRs: [MyPR] { prs.filter { !isSnoozed($0.id) } }
    var visibleIssues: [AssignedIssue] { issues.filter { !isSnoozed($0.id) } }

    var snoozedVisibleCount: Int {
        inbox.filter { isSnoozed($0.id) }.count
            + prs.filter { isSnoozed($0.id) }.count
            + issues.filter { isSnoozed($0.id) }.count
    }

    // MARK: Tab counts (chip hidden when 0)

    func count(for tab: PanelTab) -> Int {
        switch tab {
        case .inbox: return visibleInbox.count
        case .prs: return visiblePRs.count
        case .issues: return visibleIssues.count
        case .stats: return 0
        }
    }

    // MARK: Badge (menu bar)

    /// review requests + mentions + own failing PRs, minus snoozed.
    var badgeCount: Int {
        visibleInbox.count + prs.filter { $0.isFailing && !isSnoozed($0.id) }.count
    }

    /// Footer "up next": the oldest item that needs you (inbox + failing PRs).
    var upNext: (title: String, age: Age, url: URL)? {
        var candidates: [(String, Age, URL)] = visibleInbox.map { entry in
            switch entry {
            case .review(let request): return (request.title, request.age, request.url)
            case .mention(let mention): return (mention.title, mention.age, mention.url)
            }
        }
        candidates += visiblePRs.filter(\.isFailing).map { ($0.title, $0.age, $0.url) }
        return candidates
            .min(by: { $0.1.date < $1.1.date })
            .map { (title: $0.0, age: $0.1, url: $0.2) }
    }

    var statusIconState: StatusIconState {
        if snoozeAllActive { return .snoozed }
        let ciFailing = settings.alertOnCIFail
            && prs.contains(where: { $0.isFailing && !isSnoozed($0.id) })
        let count = badgeCount
        // Count mode keeps the number visible and adds the red dot beside it;
        // only dot/off modes let the red dot stand alone.
        if settings.badgeStyle == .count, count > 0 {
            return .needsYouCount(count, ciFailing: ciFailing)
        }
        if ciFailing { return .ciFailing }
        if count == 0 { return .allClear }
        switch settings.badgeStyle {
        case .count: return .needsYouCount(count, ciFailing: false)
        case .dot: return .needsYouDot
        case .off: return .allClear
        }
    }

    // MARK: Refresh

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard case .signedIn = auth else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await dataSource.refresh()
            // Filter out rows already acted on this session (spec approvedIds/
            // mergedIds) so a re-fetch — or GitHub's search-index lag — doesn't
            // resurrect them under their own confirmation lines.
            inbox = snapshot.inbox.filter { !approvedIds.contains($0.id) }
            prs = snapshot.prs.filter { !mergedIds.contains($0.id) }
            issues = snapshot.issues
            stats = snapshot.stats
            repoCI = snapshot.repoCI
            lastRefreshedAt = Date()
            inlineError = nil
            // Demo fixtures never change, so there's nothing to announce.
            if !Self.isDemo {
                Notifier.shared.process(
                    inbox: visibleInbox, prs: visiblePRs,
                    settings: settings, quiet: snoozeAllActive
                )
            }
        } catch {
            // A dead session (401 even after the refresh-token retry) drops
            // back to onboarding instead of erroring forever.
            if let gitHubError = error as? GitHubError, gitHubError.isAuthError {
                signOut()
                inlineError = "GitHub session expired — sign in again."
            } else {
                inlineError = "Refresh failed: \(error.localizedDescription)"
            }
        }
        onStateChange?()
    }

    // MARK: Actions (optimistic; restore row + inline error on API failure)

    func approve(_ request: ReviewRequest) {
        let entry = InboxEntry.review(request)
        guard let index = inbox.firstIndex(of: entry) else { return }
        inbox.remove(at: index)
        approvedIds.insert(request.id)
        onStateChange?()
        Task {
            do { try await dataSource.approve(request) }
            catch {
                approvedIds.remove(request.id)
                // A concurrent refresh may have re-added the row already.
                if !inbox.contains(where: { $0.id == entry.id }) {
                    inbox.insert(entry, at: min(index, inbox.count))
                }
                inlineError = "Approve failed — \(error.localizedDescription)"
                onStateChange?()
            }
        }
    }

    func merge(_ pr: MyPR) {
        guard let index = prs.firstIndex(of: pr) else { return }
        prs.remove(at: index)
        mergedIds.insert(pr.id)
        mergedTitles.append(pr.title)
        onStateChange?()
        Task {
            do { try await dataSource.merge(pr) }
            catch {
                mergedIds.remove(pr.id)
                // Roll back only this merge's entry (titles can repeat across repos).
                if let last = mergedTitles.lastIndex(of: pr.title) {
                    mergedTitles.remove(at: last)
                }
                // A concurrent refresh may have re-added the row already.
                if !prs.contains(where: { $0.id == pr.id }) {
                    prs.insert(pr, at: min(index, prs.count))
                }
                inlineError = "Merge failed — \(error.localizedDescription)"
                onStateChange?()
            }
        }
    }

    func rerunChecks(_ pr: MyPR) {
        guard let index = prs.firstIndex(where: { $0.id == pr.id }) else { return }
        prs[index].ci = .running(pill: "Re-running…")
        onStateChange?()
        Task { try? await dataSource.rerunChecks(pr) }
        if Self.isDemo {
            // Prototype behavior: reverts to the pre-rerun (failing) state after ~4s.
            let original = pr.ci
            rerunResetTasks[pr.id]?.cancel()
            rerunResetTasks[pr.id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // Only revert if the row still shows the optimistic state —
                // a refresh in the 4s window already wrote fresh data.
                if let i = self.prs.firstIndex(where: { $0.id == pr.id }),
                   self.prs[i].ci == .running(pill: "Re-running…") {
                    self.prs[i].ci = original
                    self.onStateChange?()
                }
            }
        }
    }

    func copyBranch(_ pr: MyPR) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.branch, forType: .string)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Snooze

    /// 9 AM next day.
    static func nextWakeTime(after date: Date = Date()) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }

    func snooze(id: String) {
        snoozed[id] = Self.nextWakeTime()
    }

    func snoozeAll() {
        let wake = Self.nextWakeTime()
        for entry in visibleInbox { snoozed[entry.id] = wake }
        for issue in visibleIssues { snoozed[issue.id] = wake }
        snoozeAllUntil = wake
        onStateChange?()
    }

    /// Wakes ALL snoozed items (the summary line counts all of them, matching
    /// the prototype's `snoozed: []` undo) — so Undo is never a dead control,
    /// including for snoozes restored from a previous launch.
    func undoSnooze() {
        snoozed = [:]
        snoozeAllUntil = nil
        onStateChange?()
    }

    // MARK: Onboarding (spec 1e)

    /// Step 1: kick off device flow, then advance to repo picking when authorized.
    func beginSignIn() {
        guard let provider = authProvider else { return }
        if case .signedOut = auth {} else { return }
        inlineError = nil
        signInTask = Task {
            do {
                let info = try await provider.startDeviceFlow()
                auth = .deviceFlow(info)
                let login = try await provider.waitForSignIn()
                // Straight in — no repo picking; items cover all repos.
                auth = .signedIn(username: login)
                startRefreshTimer()
                await refresh()
            } catch {
                // Cancelled = the user switched to token entry; not a failure.
                if Task.isCancelled { return }
                inlineError = "Sign-in failed — \(error.localizedDescription)"
                auth = .signedOut
            }
            onStateChange?()
        }
    }

    /// Switch the sign-in card to personal-access-token entry.
    func showTokenEntry() {
        signInTask?.cancel()
        signInTask = nil
        if case .deviceFlow = auth { auth = .signedOut }
        inlineError = nil
        tokenError = nil
        tokenEntryActive = true
    }

    /// Back to the device-flow code (the card restarts the flow on appear).
    func showCodeEntry() {
        tokenError = nil
        tokenEntryActive = false
    }

    /// Validate + store a personal access token, then go straight in.
    func signInWithToken(_ token: String) {
        guard let provider = authProvider, !isSigningInWithToken else { return }
        isSigningInWithToken = true
        tokenError = nil
        Task {
            do {
                let login = try await provider.signIn(withToken: token)
                auth = .signedIn(username: login)
                tokenEntryActive = false
                startRefreshTimer()
                await refresh()
            } catch {
                tokenError = error.localizedDescription
            }
            isSigningInWithToken = false
            onStateChange?()
        }
    }

    /// Refetch the repos available to watch (Settings: after an org change).
    func reloadAvailableRepos() async {
        guard let provider = authProvider else { return }
        do {
            let repos = try await provider.fetchWatchableRepos()
            settings.availableRepos = repos
            // Drop selections that no longer exist in the new list.
            let available = Set(repos.map(\.id))
            settings.watchedRepos = settings.watchedRepos.intersection(available)
            inlineError = nil
        } catch {
            inlineError = "Could not load repos — \(error.localizedDescription)"
        }
    }

    /// Step 2 "Start watching".
    func completeOnboarding(selectedRepos: Set<String>) {
        settings.watchedRepos = selectedRepos
        auth = .signedIn(username: pendingUsername ?? "you")
        startRefreshTimer()
        Task { await refresh() }
    }

    func signOut() {
        authProvider?.signOut()
        tokenEntryActive = false
        auth = .signedOut
        inbox = []; prs = []; issues = []; stats = nil; repoCI = []
        onStateChange?()
    }

    // MARK: Factory

    static func make() -> AppState {
        let settings = SettingsStore()
        if isDemo {
            // QUEUE_ONBOARDING=1 starts signed out to exercise spec 1e.
            let onboarding = ProcessInfo.processInfo.environment["QUEUE_ONBOARDING"] == "1"
            let state = AppState(
                settings: settings,
                dataSource: MockDataSource(),
                auth: onboarding ? .signedOut : .signedIn(username: "rdejong")
            )
            state.authProvider = MockAuthProvider()
            Task { await state.refresh() }
            return state
        }
        // Live mode: GitHubDataSource takes over after onboarding/auth.
        return LiveBootstrap.makeState(settings: settings)
    }
}
