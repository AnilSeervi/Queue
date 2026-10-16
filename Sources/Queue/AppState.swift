import AppKit
import SwiftUI

// MARK: - Data source abstraction

/// Sections of a refresh that can fail independently.
enum SnapshotSection: String, Hashable, CaseIterable {
    case reviews, mentions, prs, issues, stats, done
}

/// SAML single sign-on state reported by GitHub (X-GitHub-SSO header or a
/// GraphQL FORBIDDEN on an org).
enum SSONotice: Hashable {
    /// A request was refused until the token is authorized for SSO.
    case required(authorizeURL: URL)
    /// Results omitted items from these orgs (token not authorized for them).
    case partialResults(orgs: [String])
}

struct Snapshot {
    var inbox: [InboxEntry]
    var prs: [MyPR]
    var issues: [AssignedIssue]
    var stats: StatsData?
    /// Sections that failed this refresh, with GitHub's message. The app keeps
    /// the previous data for these instead of showing them as empty.
    var failed: [SnapshotSection: String] = [:]
    var sso: SSONotice? = nil
    /// Reviews you submitted on others' PRs within `doneWindow`, newest first
    /// (includes reviews done on github.com). Section `.done`.
    var doneReviews: [DoneItem] = []
    /// Your PRs merged within `doneWindow`, newest first. Section `.done`.
    var mergedPRs: [DoneItem] = []

    /// Inbox entries split by section (reviews vs mentions fail independently).
    var reviewEntries: [InboxEntry] { inbox.filter { if case .review = $0 { return true }; return false } }
    var mentionEntries: [InboxEntry] { inbox.filter { if case .mention = $0 { return true }; return false } }
}

/// Implemented by MockDataSource (demo) and GitHubDataSource (live).
protocol QueueDataSource {
    func refresh() async throws -> Snapshot
    /// Approve, pinned to `request.headSHA`.
    func approve(_ request: ReviewRequest) async throws
    /// Merge with `pr.mergeMethod`, pinned to `pr.headSHA` (409 if it moved).
    func merge(_ pr: MyPR) async throws
    /// Re-run failed jobs in every run in `pr.failedRunIDs`; returns how many
    /// runs were re-run. Throws only if none could be.
    func rerunChecks(_ pr: MyPR) async throws -> Int
    /// PATCH notifications/threads/{id} (mark read). Best-effort.
    func markThreadRead(_ threadID: String) async throws
    /// For review requests that vanished from the inbox, what happened:
    /// keyed by ReviewRequest.id → a DoneItem (your review, merged/closed
    /// without you, or request removed). Omits requests still pending or
    /// that couldn't be resolved.
    func resolveReviewRequests(_ requests: [ReviewRequest]) async throws -> [String: DoneItem]
}

/// Auth boundary between onboarding UI and the GitHub integration.
protocol AuthProvider {
    /// Begin the OAuth device flow; returns the user code + verification URL to display.
    func startDeviceFlow() async throws -> DeviceFlowInfo
    /// Poll until the user authorizes; stores the token (Keychain) and returns the login.
    func waitForSignIn() async throws -> String
    /// Validate a personal access token, store it (Keychain), return the login.
    func signIn(withToken token: String) async throws -> String
    /// Clear stored credentials (Keychain token, cached login).
    func signOut()
    /// False when no OAuth client ID is configured (e.g. a downloaded release):
    /// the sign-in card then goes straight to token entry.
    var supportsDeviceFlow: Bool { get }
}

extension AuthProvider {
    func signOut() {}
    var supportsDeviceFlow: Bool { true }
    func signIn(withToken token: String) async throws -> String {
        throw GitHubError.api("Token sign-in isn't available.")
    }
}

// MARK: - Settings

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var badgeStyle: BadgeStyle { didSet { defaults.set(badgeStyle.rawValue, forKey: "badgeStyle") } }
    @Published var alertOnCIFail: Bool { didSet { defaults.set(alertOnCIFail, forKey: "alertOnCIFail") } }
    // Notifications, one toggle per event type (all on by default).
    @Published var notifyReviewRequests: Bool { didSet { defaults.set(notifyReviewRequests, forKey: "notifyReviewRequests") } }
    @Published var notifyMentions: Bool { didSet { defaults.set(notifyMentions, forKey: "notifyMentions") } }
    @Published var notifyCIFailures: Bool { didSet { defaults.set(notifyCIFailures, forKey: "notifyCIFailures") } }
    @Published var notifyPRReady: Bool { didSet { defaults.set(notifyPRReady, forKey: "notifyPRReady") } }

    /// Keys of removed features — the repo picker and footer CI strip (Queue
    /// covers all your repos now), hiding items until morning — and of values
    /// now read from the system: launch at login (SMAppService) and the
    /// shortcut chip (the registered hotkey).
    private static let retiredKeys = [
        "organization", "watchedRepos", "showCIStrip", "onlyNeedsMe", "launchAtLogin", "shortcutDisplay",
        "snoozed", "snoozeAllUntil",
    ]

    init() {
        refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 120
        badgeStyle = BadgeStyle(rawValue: defaults.string(forKey: "badgeStyle") ?? "") ?? .count
        alertOnCIFail = defaults.object(forKey: "alertOnCIFail") as? Bool ?? true
        notifyReviewRequests = defaults.object(forKey: "notifyReviewRequests") as? Bool ?? true
        notifyMentions = defaults.object(forKey: "notifyMentions") as? Bool ?? true
        notifyCIFailures = defaults.object(forKey: "notifyCIFailures") as? Bool ?? true
        notifyPRReady = defaults.object(forKey: "notifyPRReady") as? Bool ?? true

        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore
    var dataSource: QueueDataSource

    // Data. A section that fails to refresh keeps its last good rows.
    @Published var inbox: [InboxEntry] = []
    @Published var prs: [MyPR] = []
    @Published var issues: [AssignedIssue] = []
    @Published var stats: StatsData?
    /// Last refresh in which review requests, mentions and your PRs all
    /// loaded (the footer's "↻ 2m"). nil until then and after sign-out.
    @Published private(set) var lastRefreshedAt: Date?
    /// A refresh is running (single-flight, see refresh()).
    @Published private(set) var isRefreshing = false
    /// Sections that have loaded at least once since sign-in.
    @Published private(set) var loadedSections: Set<SnapshotSection> = []
    /// GitHub's latest SAML SSO notice (nil = none). A refresh that failed
    /// without reporting one keeps the previous notice.
    @Published private(set) var ssoNotice: SSONotice?

    /// Review requests, mentions and your PRs have each loaded once, so the
    /// badge means something. Until then the tabs show "Loading…" (or
    /// inlineError, when a load failed) and the icon is `.loading`.
    var hasLoaded: Bool { loadedSections.isSuperset(of: Self.badgeSections) }

    // UI
    @Published var activeTab: PanelTab {
        didSet { UserDefaults.standard.set(activeTab.rawValue, forKey: "activeTab") }
    }
    @Published var auth: AuthState

    // Session mutations (spec "State Management": session approvedIds/mergedIds).
    // refresh() filters re-fetched rows against these so acted-on items don't
    // resurrect (GitHub's search index lags a write) while the summary lines
    // still show them as done. signOut() clears them.
    /// Review request id → when you approved it. The row stays hidden for
    /// `approvalHold`, and only while the PR hasn't changed since — new
    /// commits and a re-request bring it straight back.
    private var approvedAt: [String: Date] = [:]
    @Published private(set) var approvedThisSession = 0
    @Published var mergedIds: Set<String> = []
    /// Titles for the "Merged · <title>" confirmation line, in merge order.
    @Published var mergedTitles: [String] = []
    /// Mention threads marked read this session (thread id → its updated_at
    /// then), so a refresh already in flight can't bring the row back.
    private var readThisSession: [String: Date] = [:]
    @Published var inlineError: String?

    // Done: what you've dealt with in the last `doneWindow` (doneInbox,
    // donePRs). A refresh whose done searches failed keeps the last good
    // lists, like every other section.
    @Published private var doneReviewsOnGitHub: [DoneItem] = []
    @Published private var mergedOnGitHub: [DoneItem] = []
    /// What Queue saw you deal with, and the review requests it last saw
    /// (saved; see DoneLog). Demo mode keeps it in memory.
    @Published private var doneLog: DoneLog {
        didSet { if !Self.isDemo { doneLog.save() } }
    }
    /// Tabs whose Done section is open, for this launch only.
    @Published var expandedDone: Set<PanelTab> = []
    /// A resolveReviewRequests call is running (one at a time).
    private var resolvingRequests = false

    /// The last failed approve / merge / re-run. It holds the error line
    /// across refreshes (opening the panel often starts one just as you act)
    /// until your next action or `actionErrorHold`, whichever comes first.
    private var actionError: (message: String, at: Date)?
    /// What the last refresh had to say (staleDataMessage), shown again once
    /// an action error is dismissed.
    private var refreshStatus: String?

    /// Ticks when the status icon needs re-render; observed by StatusItemController.
    var onStateChange: (() -> Void)?
    /// Wired by AppDelegate: opens the Settings window (footer gear).
    var openSettingsWindow: (() -> Void)?
    /// Wired by AppDelegate: closes the panel (used after deep-linking out).
    var closePanel: (() -> Void)?

    var authProvider: AuthProvider?
    /// The in-flight device-flow task, cancelled when switching to token entry.
    private var signInTask: Task<Void, Never>?

    // Token sign-in (alternative to the device flow).
    @Published var tokenEntryActive = false
    @Published var isSigningInWithToken = false
    @Published var tokenError: String?

    static let sessionExpiredMessage = "GitHub session expired — sign in again."
    static let tokenExpiredMessage = "Your token expired or was revoked — paste a new one."

    /// How long an approved review request stays hidden while GitHub catches up.
    static let approvalHold: TimeInterval = 10 * 60
    /// Approving bumps the PR's updatedAt itself (on GitHub's clock), so a
    /// change only counts once it's this much newer than the approval.
    private static let approvalSlack: TimeInterval = 60
    /// Opening the panel refreshes when the last refresh is older than this.
    static let staleAfter: TimeInterval = 60
    /// A refresh that failed is retried once, this much later.
    static let retryDelay: TimeInterval = 15
    /// How long a failed action's message outlasts refreshes.
    static let actionErrorHold: TimeInterval = 2 * 60
    /// The sections behind the badge, Up next and lastRefreshedAt.
    private static let badgeSections: Set<SnapshotSection> = [.reviews, .mentions, .prs]

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    /// Bumped by signOut(): work started before it must not land after it.
    private var sessionGeneration = 0
    /// When each section last loaded ("showing data from 3m ago").
    private var sectionLoadedAt: [SnapshotSection: Date] = [:]
    /// When the last refresh pass finished, whatever its outcome.
    private var lastAttemptAt: Date?
    /// The one retry since the last fully successful refresh has run.
    private var retriedSinceSuccess = false
    /// A pending one-off refresh: the retry after a failure, or the look at
    /// re-run checks. Any refresh pass cancels it.
    private var followUpTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var wakeTask: Task<Void, Never>?
    private var rerunResetTasks: [String: Task<Void, Never>] = [:]

    static var isDemo: Bool { ProcessInfo.processInfo.environment["QUEUE_DEMO"] == "1" }

    init(settings: SettingsStore, dataSource: QueueDataSource, auth: AuthState) {
        self.settings = settings
        self.dataSource = dataSource
        self.auth = auth
        self.activeTab = PanelTab(rawValue: UserDefaults.standard.string(forKey: "activeTab") ?? "") ?? .inbox
        self.doneLog = Self.isDemo
            ? DoneLog(login: MockData.login, items: MockData.loggedDone)
            : DoneLog.load() ?? DoneLog(login: "")
        if case .signedIn(let login) = auth { claimDoneLog(for: login) }
    }

    // MARK: Tab counts (chip hidden when 0)

    func count(for tab: PanelTab) -> Int {
        switch tab {
        case .inbox: return inbox.count
        case .prs: return prs.count
        case .issues: return issues.count
        case .stats: return 0
        }
    }

    // MARK: Done (the collapsed rows at the end of Inbox and My PRs)

    /// Inbox items dealt with in the last `doneWindow`, newest first: the
    /// reviews you submitted (from GitHub, so reviews on github.com count)
    /// and what Queue logged — mentions you cleared, requests that went away
    /// without your review. One row per PR or thread, and none for one
    /// that's back in the inbox (asked again, or new activity).
    var doneInbox: [DoneItem] {
        let open = Set(inbox.map { entry -> String in
            switch entry {
            case .review(let request): return DoneItem.prID(request.repo, request.number)
            case .mention(let mention): return DoneItem.threadID(mention.threadID)
            }
        })
        let logged = doneLog.items.filter { $0.outcome != .merged }
        return DoneItem.combine(doneReviewsOnGitHub + logged, now: Date())
            .filter { !open.contains($0.id) }
    }

    /// Your PRs merged in the last `doneWindow`, newest first, including
    /// ones merged here that GitHub's search hasn't caught up with.
    var donePRs: [DoneItem] {
        let logged = doneLog.items.filter { $0.outcome == .merged }
        return DoneItem.combine(mergedOnGitHub + logged, now: Date())
    }

    func toggleDone(_ tab: PanelTab) {
        if expandedDone.contains(tab) { expandedDone.remove(tab) } else { expandedDone.insert(tab) }
    }

    // MARK: Badge (menu bar)

    /// review requests + mentions + your PRs that need you (failing CI,
    /// changes requested or conflicts; each PR counted once).
    var badgeCount: Int {
        inbox.count + prs.filter(\.needsYou).count
    }

    /// Footer "up next": the oldest item that needs you (inbox + your PRs
    /// that need you).
    var upNext: (title: String, age: Age, url: URL)? {
        var candidates: [(String, Age, URL)] = inbox.map { entry in
            switch entry {
            case .review(let request): return (request.title, request.age, request.url)
            case .mention(let mention): return (mention.title, mention.age, mention.url)
            }
        }
        candidates += prs.filter(\.needsYou).map { ($0.title, $0.age, $0.url) }
        return candidates
            .min(by: { $0.1.date < $1.1.date })
            .map { (title: $0.0, age: $0.1, url: $0.2) }
    }

    var statusIconState: StatusIconState {
        // Signed out or not loaded yet: unknown, which must not read as all clear.
        guard hasLoaded else { return .loading }
        let ciFailing = settings.alertOnCIFail && prs.contains(where: \.isFailing)
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
        let interval = settings.refreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Lets macOS fold the wake-up in with other timers.
        timer.tolerance = interval * 0.1
        refreshTimer = timer
    }

    /// Single-flight: a call while a refresh is running waits for that one
    /// instead of starting another, so overlapping triggers (timer, footer,
    /// menu, panel open, wake) can't land an older snapshot after a newer
    /// one. `queueIfBusy` runs one more pass after the running one — for
    /// sign-in, where the running pass may belong to the previous session.
    func refresh(queueIfBusy: Bool = false) async {
        guard case .signedIn = auth else { return }
        if let running = refreshTask {
            if queueIfBusy { refreshQueued = true }
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshQueued = false
                await self.refreshOnce()
            } while self.refreshQueued
            self.refreshTask = nil
            self.isRefreshing = false
        }
        refreshTask = task
        isRefreshing = true
        await task.value
    }

    /// Panel open: refresh if the last refresh finished over `staleAfter`
    /// ago. Timed from the last attempt rather than lastRefreshedAt, so a
    /// section that keeps failing isn't refetched on every open (the retry
    /// after a failure covers that).
    func refreshIfStale() {
        guard case .signedIn = auth else { return }
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < Self.staleAfter { return }
        Task { await refresh() }
    }

    /// After the Mac wakes: a Timer doesn't count time asleep, so the data
    /// can be hours old. Waits a few seconds for Wi-Fi to rejoin; if that
    /// isn't enough, the retry after a failed refresh follows.
    func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterWake() }
        }
    }

    private func refreshAfterWake() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.startRefreshTimer()
            await self.refresh()
        }
    }

    private func refreshOnce() async {
        guard case .signedIn(let login) = auth else { return }
        let generation = sessionGeneration
        followUpTask?.cancel()
        followUpTask = nil
        let snapshot: Snapshot
        do {
            snapshot = try await dataSource.refresh()
        } catch let error as GitHubError where error.isAuthError {
            // A dead session (401 even after the refresh-token retry) drops
            // back to sign-in instead of erroring forever.
            if generation == sessionGeneration { sessionExpired() }
            return
        } catch {
            // Nothing came back at all (e.g. offline): every section failed.
            let message = error.localizedDescription
            snapshot = Snapshot(
                inbox: [], prs: [], issues: [], stats: nil,
                failed: Dictionary(uniqueKeysWithValues: SnapshotSection.allCases.map { ($0, message) })
            )
        }
        guard generation == sessionGeneration else { return }   // signed out meanwhile
        apply(snapshot, login: login)
    }

    /// Takes the sections that loaded and keeps the last good rows for the
    /// rest, so a failed fetch never reads as "Nothing needs you".
    private func apply(_ snapshot: Snapshot, login: String) {
        let now = Date()
        let failed = snapshot.failed
        func loaded(_ section: SnapshotSection) -> Bool { failed[section] == nil }
        claimDoneLog(for: login)

        approvedAt = approvedAt.filter { now.timeIntervalSince($0.value) < Self.approvalHold }
        let reviews: [InboxEntry]
        if loaded(.reviews) {
            let fetched = snapshot.reviewEntries
            let ids = Set(fetched.map(\.id))
            trackReviewRequests(
                fetched.compactMap { if case .review(let request) = $0 { return request }; return nil },
                approvedHere: Set(approvedAt.keys), now: now
            )
            approvedAt = approvedAt.filter { ids.contains($0.key) }
            reviews = fetched.filter { !isHeldAfterApproval($0, now: now) }
        } else {
            reviews = inbox.filter(\.isReview)
        }
        let mentions: [InboxEntry]
        if loaded(.mentions) {
            let fetched = snapshot.mentionEntries
            let threads = Set(fetched.compactMap { entry -> String? in
                if case .mention(let mention) = entry { return mention.threadID }
                return nil
            })
            readThisSession = readThisSession.filter { threads.contains($0.key) }
            mentions = fetched.filter { !isMarkedRead($0) }
        } else {
            mentions = inbox.filter { !$0.isReview }
        }
        // Reviews first, then mentions; groupByRepo keeps per-repo order.
        inbox = reviews + mentions
        if loaded(.prs) { prs = snapshot.prs.filter { !mergedIds.contains($0.id) } }
        if loaded(.issues) { issues = snapshot.issues }
        if loaded(.stats) { stats = snapshot.stats }
        if loaded(.done) {
            doneReviewsOnGitHub = snapshot.doneReviews
            mergedOnGitHub = snapshot.mergedPRs
        }
        var log = doneLog
        if log.prune(now: now) { doneLog = log }

        let fresh = Set(SnapshotSection.allCases.filter(loaded))
        for section in fresh { sectionLoadedAt[section] = now }
        if !fresh.isSubset(of: loadedSections) { loadedSections.formUnion(fresh) }
        if Self.badgeSections.isSubset(of: fresh) { lastRefreshedAt = now }
        lastAttemptAt = now
        refreshStatus = staleDataMessage(failed)
        if let error = actionError, now.timeIntervalSince(error.at) >= Self.actionErrorHold { actionError = nil }
        inlineError = actionError?.message ?? refreshStatus
        if let sso = snapshot.sso {
            ssoNotice = sso
        } else if failed.isEmpty {
            ssoNotice = nil
        }

        if failed.isEmpty {
            retriedSinceSuccess = false
        } else if !retriedSinceSuccess {
            scheduleRefresh(after: Self.retryDelay, isRetry: true)
        }

        // Demo fixtures never change, so there's nothing to announce.
        if !Self.isDemo {
            Notifier.shared.process(
                inbox: inbox, prs: prs, failed: Set(failed.keys), login: login, settings: settings
            )
        }
        onStateChange?()
    }

    /// Approved this session, still within the hold, and the PR hasn't
    /// changed since.
    private func isHeldAfterApproval(_ entry: InboxEntry, now: Date) -> Bool {
        guard case .review(let request) = entry,
              let approved = approvedAt[request.id],
              now.timeIntervalSince(approved) < Self.approvalHold
        else { return false }
        guard let updated = request.updatedAt else { return true }
        return updated <= approved.addingTimeInterval(Self.approvalSlack)
    }

    private func isMarkedRead(_ entry: InboxEntry) -> Bool {
        guard case .mention(let mention) = entry else { return false }
        return ReadThreads.isRead(
            threadID: mention.threadID, updatedAt: mention.threadUpdatedAt, markers: readThisSession
        )
    }

    /// "Couldn't refresh Inbox — showing data from 3m ago (GitHub timed
    /// out)", or "Couldn't load …" when a failed section never loaded.
    /// nil when nothing failed.
    private func staleDataMessage(_ failed: [SnapshotSection: String]) -> String? {
        let sections = SnapshotSection.allCases.filter { failed[$0] != nil }
        guard let first = sections.first, var reason = failed[first] else { return nil }
        if reason.hasSuffix(".") { reason.removeLast() }
        let names = sections.count == SnapshotSection.allCases.count ? nil : Self.describe(sections)
        let loadedAt = sections.compactMap { sectionLoadedAt[$0] }
        guard loadedAt.count == sections.count, let oldest = loadedAt.min() else {
            return "Couldn't load \(names ?? "from GitHub") (\(reason))"
        }
        let what = names.map { " \($0)" } ?? ""
        return "Couldn't refresh\(what) — showing data from \(Age(date: oldest).display) ago (\(reason))"
    }

    /// "Inbox", "mentions and My PRs", "review requests, Issues and Stats".
    private static func describe(_ sections: [SnapshotSection]) -> String {
        let set = Set(sections)
        var names: [String] = []
        switch (set.contains(.reviews), set.contains(.mentions)) {
        case (true, true): names.append("Inbox")
        case (true, false): names.append("review requests")
        case (false, true): names.append("mentions")
        case (false, false): break
        }
        if set.contains(.prs) { names.append("My PRs") }
        if set.contains(.issues) { names.append("Issues") }
        if set.contains(.stats) { names.append("Stats") }
        if set.contains(.done) { names.append("done items") }
        guard let last = names.popLast() else { return "" }
        return names.isEmpty ? last : "\(names.joined(separator: ", ")) and \(last)"
    }

    /// Replaces any pending follow-up refresh.
    private func scheduleRefresh(after delay: TimeInterval, isRetry: Bool = false) {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.followUpTask = nil
            if isRetry { self.retriedSinceSuccess = true }
            await self.refresh()
        }
    }

    // MARK: Done log

    /// The log belongs to one account: another login starts it over (and
    /// the next load sets a new review-request baseline).
    private func claimDoneLog(for login: String) {
        guard doneLog.login.caseInsensitiveCompare(login) != .orderedSame else { return }
        doneLog = DoneLog(login: login)
        doneReviewsOnGitHub = []
        mergedOnGitHub = []
    }

    /// Notes the review requests a good load listed, and asks GitHub what
    /// became of the ones listed last time and gone now, except those you
    /// approved here (already logged). The first load only sets the baseline.
    private func trackReviewRequests(_ requests: [ReviewRequest], approvedHere: Set<String>, now: Date) {
        var log = doneLog
        let current = requests.map { KnownRequest($0, seenAt: now) }
        let ids = Set(current.map(\.id))
        if let previous = log.knownRequests {
            let gone = previous.filter { !ids.contains($0.id) }
            if requests.count >= QueueGraphQL.maxItems {
                // A clipped search would make the requests past the cap look
                // gone: keep them known instead.
                log.knownRequests = current + gone
            } else {
                log.knownRequests = current
                let waiting = Set(log.vanished.map(\.id))
                log.vanished += gone.filter { !approvedHere.contains($0.id) && !waiting.contains($0.id) }
            }
        } else {
            log.knownRequests = current
        }
        // Asked again before GitHub said why it went: still open, nothing to log.
        log.vanished.removeAll { ids.contains($0.id) }
        doneLog = log
        resolveVanishedRequests()
    }

    /// One lookup at a time, for every request waiting; a lookup that
    /// fails outright is retried after the next good load, up to
    /// `DoneLog.maxLookups` times.
    private func resolveVanishedRequests() {
        guard !resolvingRequests, !doneLog.vanished.isEmpty else { return }
        let batch = doneLog.vanished
        let generation = sessionGeneration
        let source = dataSource
        resolvingRequests = true
        Task {
            let result: Result<[String: DoneItem], Error>
            do { result = .success(try await source.resolveReviewRequests(batch.map(\.request))) }
            catch { result = .failure(error) }
            // Signed out meanwhile: signOut() reset the flag, and the log
            // unless the session expired (then the next load retries these).
            guard generation == sessionGeneration else { return }
            resolvingRequests = false
            var log = doneLog
            let sent = Set(batch)
            switch result {
            case .success(let resolved):
                log.vanished.removeAll { sent.contains($0) }
                for item in resolved.values { log.record(item) }
                _ = log.prune(now: Date())
            case .failure(let error):
                NSLog("Queue: couldn't look up %d review requests that went away: %@",
                      batch.count, error.localizedDescription)
                for index in log.vanished.indices where sent.contains(log.vanished[index]) {
                    log.vanished[index].failedLookups += 1
                }
                log.vanished.removeAll { $0.failedLookups >= DoneLog.maxLookups }
            }
            doneLog = log
        }
    }

    /// Logs something you just dealt with here. Returns the entry it
    /// replaced, so a failed action can put that back (`unlogDone`).
    @discardableResult
    private func logDone(_ item: DoneItem) -> DoneItem? {
        guard case .signedIn(let login) = auth else { return nil }
        claimDoneLog(for: login)
        var log = doneLog
        let previous = log.items.first { $0.id == item.id }
        log.record(item)
        doneLog = log
        return previous
    }

    /// Takes back `item` after its action failed, restoring what it
    /// replaced, unless something newer has replaced it since.
    private func unlogDone(_ item: DoneItem, restoring previous: DoneItem?) {
        var log = doneLog
        guard let index = log.items.firstIndex(of: item) else { return }
        if let previous { log.items[index] = previous } else { log.items.remove(at: index) }
        doneLog = log
    }

    private static func doneItem(_ request: ReviewRequest, _ outcome: DoneOutcome) -> DoneItem {
        DoneItem(id: DoneItem.prID(request.repo, request.number), repo: request.repo, number: request.number,
                 title: request.title, url: request.url, doneAt: Date(), outcome: outcome)
    }

    // MARK: Actions (optimistic; restore row + inline error on API failure)

    /// Shows why an action failed; see `actionError`.
    private func reportActionError(_ message: String) {
        actionError = (message, Date())
        inlineError = message
        onStateChange?()
    }

    /// A new action dismisses the previous action's error.
    private func clearActionError() {
        guard let error = actionError else { return }
        actionError = nil
        if inlineError == error.message { inlineError = refreshStatus }
    }

    func approve(_ request: ReviewRequest) {
        let entry = InboxEntry.review(request)
        guard let index = inbox.firstIndex(of: entry) else { return }
        clearActionError()
        let generation = sessionGeneration
        inbox.remove(at: index)
        approvedAt[request.id] = Date()
        approvedThisSession += 1
        // In Done at once; GitHub's search lists the review a little later.
        let done = Self.doneItem(request, .approved)
        let replaced = logDone(done)
        onStateChange?()
        Task {
            do {
                try await dataSource.approve(request)
                // Hold from when GitHub has the review, not from the click.
                if approvedAt[request.id] != nil { approvedAt[request.id] = Date() }
            } catch {
                guard generation == sessionGeneration else { return }
                approvedAt.removeValue(forKey: request.id)
                approvedThisSession -= 1
                unlogDone(done, restoring: replaced)
                // A concurrent refresh may have re-added the row already.
                if !inbox.contains(where: { $0.id == entry.id }) {
                    inbox.insert(entry, at: min(index, inbox.count))
                }
                reportActionError("Approve failed — \(error.localizedDescription)")
            }
        }
    }

    func merge(_ pr: MyPR) {
        guard let index = prs.firstIndex(of: pr) else { return }
        clearActionError()
        let generation = sessionGeneration
        prs.remove(at: index)
        mergedIds.insert(pr.id)
        mergedTitles.append(pr.title)
        // In Done at once, until GitHub's search lists the merge.
        let done = DoneItem(id: DoneItem.prID(pr.repo, pr.number), repo: pr.repo, number: pr.number,
                            title: pr.title, url: pr.url, doneAt: Date(), outcome: .merged)
        let replaced = logDone(done)
        onStateChange?()
        Task {
            do { try await dataSource.merge(pr) }
            catch {
                guard generation == sessionGeneration else { return }
                mergedIds.remove(pr.id)
                unlogDone(done, restoring: replaced)
                // Roll back only this merge's entry (titles can repeat across repos).
                if let last = mergedTitles.lastIndex(of: pr.title) {
                    mergedTitles.remove(at: last)
                }
                // A concurrent refresh may have re-added the row already.
                if !prs.contains(where: { $0.id == pr.id }) {
                    prs.insert(pr, at: min(index, prs.count))
                }
                reportActionError("Merge failed — \(error.localizedDescription)")
            }
        }
    }

    private static let rerunningCI = CIState.running(pill: "Re-running…")

    /// Optimistic "Re-running…" pill while GitHub re-runs every failed
    /// Actions run. If it refused them all, the row goes back to what it
    /// showed and the reason surfaces; otherwise a refresh ~15s later shows
    /// the queued runs.
    func rerunChecks(_ pr: MyPR) {
        guard let index = prs.firstIndex(where: { $0.id == pr.id }) else { return }
        clearActionError()
        let original = prs[index].ci
        let generation = sessionGeneration
        prs[index].ci = Self.rerunningCI
        onStateChange?()
        Task {
            do {
                _ = try await dataSource.rerunChecks(pr)
                guard generation == sessionGeneration else { return }
                if Self.isDemo {
                    // Prototype behavior: back to the pre-rerun state after ~4s.
                    rerunResetTasks[pr.id]?.cancel()
                    rerunResetTasks[pr.id] = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.rerunResetTasks[pr.id] = nil
                        self.undoRerunPill(pr.id, to: original)
                    }
                } else {
                    scheduleRefresh(after: 15)
                }
            } catch {
                guard generation == sessionGeneration else { return }
                undoRerunPill(pr.id, to: original)
                reportActionError("Re-run failed — \(error.localizedDescription)")
            }
        }
    }

    /// Only if the row still shows the optimistic state — a refresh in
    /// between already wrote fresh data.
    private func undoRerunPill(_ id: String, to original: CIState) {
        guard let i = prs.firstIndex(where: { $0.id == id }), prs[i].ci == Self.rerunningCI else { return }
        prs[i].ci = original
        onStateChange?()
    }

    /// Opened or ✓ Done on a mention row: drop it, mark its thread read and
    /// list it under Done.
    func markRead(_ mention: Mention) {
        inbox.removeAll { $0.id == mention.id }
        logCleared(mention)
        onStateChange?()
        markThreadRead(mention.threadID, updatedAt: mention.threadUpdatedAt)
    }

    private func logCleared(_ mention: Mention) {
        guard !mention.threadID.isEmpty else { return }
        logDone(.cleared(mention))
    }

    /// Marks a mention thread read: locally first (ReadThreads keeps the row
    /// hidden until the thread has newer activity, even if GitHub's feed
    /// lags or the PATCH fails), then on GitHub, with no rollback. Also used
    /// when a mention notification is clicked, after its row may be gone
    /// (or before the first load, when the click launched Queue): `done` is
    /// the notified row's Done entry, logged when there's no row to log.
    func markThreadRead(_ threadID: String, updatedAt: Date?, done: DoneItem? = nil) {
        guard !threadID.isEmpty else { return }
        var stamp = updatedAt
        let before = inbox.count
        var cleared: Mention?
        inbox.removeAll { entry in
            guard case .mention(let mention) = entry, mention.threadID == threadID else { return false }
            stamp = mention.threadUpdatedAt ?? stamp
            cleared = mention
            return true
        }
        if let cleared {
            logCleared(cleared)
        } else if var done {
            done.doneAt = Date()
            logDone(done)
        }
        if inbox.count != before { onStateChange?() }
        readThisSession[threadID] = stamp ?? Date()
        // Demo threads aren't real; keep them out of the stored markers.
        guard !Self.isDemo else { return }
        ReadThreads.mark(threadID, updatedAt: stamp)
        let source = dataSource
        Task { try? await source.markThreadRead(threadID) }
    }

    func copyBranch(_ pr: MyPR) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.branch, forType: .string)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Onboarding (spec 1e)

    /// False when no OAuth client ID is configured: the sign-in card goes
    /// straight to token entry and has no code to fall back to.
    var supportsDeviceFlow: Bool { authProvider?.supportsDeviceFlow ?? true }

    /// Start the device flow and go straight in once authorized. Without a
    /// client ID, opens token entry instead.
    func beginSignIn() {
        guard let provider = authProvider else { return }
        if case .signedOut = auth {} else { return }
        guard provider.supportsDeviceFlow else {
            tokenEntryActive = true
            return
        }
        // "Session expired" is why the card is showing; keep it up while a
        // new code is fetched.
        if inlineError != Self.sessionExpiredMessage { inlineError = nil }
        signInTask = Task {
            do {
                let info = try await provider.startDeviceFlow()
                auth = .deviceFlow(info)
                let login = try await provider.waitForSignIn()
                // Straight in — no repo picking; items cover all repos.
                auth = .signedIn(username: login)
                inlineError = nil
                startRefreshTimer()
                await refresh(queueIfBusy: true)
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
        guard supportsDeviceFlow else { return }
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
                inlineError = nil
                startRefreshTimer()
                await refresh(queueIfBusy: true)
            } catch {
                tokenError = error.localizedDescription
            }
            isSigningInWithToken = false
            onStateChange?()
        }
    }

    /// A 401 that survived the refresh-token retry. Token users go back to
    /// token entry (theirs expired or was revoked); device-flow users get a
    /// new code. Notifier and the Done log keep what they have: it's usually
    /// the same account coming back, and another login starts both over
    /// (claimDoneLog).
    private func sessionExpired() {
        signOut(keepingDoneLog: true)
        let method = UserDefaults.standard.string(forKey: GitHubAuth.authMethodKey)
        if method == "pat" || !supportsDeviceFlow {
            tokenEntryActive = true
            tokenError = Self.tokenExpiredMessage
        } else {
            inlineError = Self.sessionExpiredMessage
        }
    }

    /// `keepingDoneLog`: the session expired (see sessionExpired).
    func signOut(keepingDoneLog: Bool = false) {
        sessionGeneration += 1
        followUpTask?.cancel()
        followUpTask = nil
        rerunResetTasks.values.forEach { $0.cancel() }
        rerunResetTasks = [:]
        authProvider?.signOut()
        auth = .signedOut
        tokenEntryActive = !supportsDeviceFlow
        tokenError = nil
        inlineError = nil
        actionError = nil
        refreshStatus = nil
        inbox = []; prs = []; issues = []; stats = nil
        lastRefreshedAt = nil
        lastAttemptAt = nil
        loadedSections = []
        sectionLoadedAt = [:]
        retriedSinceSuccess = false
        ssoNotice = nil
        // This session's acted-on rows belong to the account signing out,
        // and so does what it has done (the saved log goes too, unless the
        // session only expired).
        approvedAt = [:]
        approvedThisSession = 0
        mergedIds = []
        mergedTitles = []
        readThisSession = [:]
        doneReviewsOnGitHub = []
        mergedOnGitHub = []
        if !keepingDoneLog { doneLog = DoneLog(login: "") }
        resolvingRequests = false
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
                auth: onboarding ? .signedOut : .signedIn(username: MockData.login)
            )
            state.authProvider = MockAuthProvider()
            return state
        }
        // Live mode: GitHubDataSource takes over after onboarding/auth.
        return LiveBootstrap.makeState(settings: settings)
    }
}
