import SwiftUI

// MARK: - Repos

struct RepoRef: Hashable, Codable, Comparable {
    var owner: String
    var name: String

    var fullName: String { "\(owner)/\(name)" }
    var shortName: String { name }
    var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

    /// Finder-style name order (case-insensitive, "app2" before "app10").
    static func < (lhs: RepoRef, rhs: RepoRef) -> Bool {
        switch lhs.fullName.localizedStandardCompare(rhs.fullName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.fullName < rhs.fullName
        }
    }
}

// MARK: - Ages

/// Compact GitHub-style relative age ("40m", "2h", "1d") + staleness (≥3d → amber).
struct Age: Hashable {
    var date: Date

    var display: String {
        let s = max(0, -date.timeIntervalSinceNow)
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    var isStale: Bool { -date.timeIntervalSinceNow >= 3 * 24 * 3600 }
}

// MARK: - Inbox

struct UserRef: Hashable, Codable {
    var login: String

    var initials: String {
        String(login.prefix(2)).uppercased()
    }

    /// Deterministic per-user avatar color.
    var avatarColor: Color {
        let palette: [UInt32] = [0x5B8DEF, 0x9B6BD8, 0x2FA57F, 0xD86B8A, 0xC98A2D, 0x5AA7C7, 0xB25BB2, 0x7A8A3A]
        var hash: UInt32 = 5381
        for b in login.utf8 { hash = hash &* 33 &+ UInt32(b) }
        return Color(hex: palette[Int(hash % UInt32(palette.count))])
    }
}

struct ReviewRequest: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    var title: String
    var author: UserRef
    var additions: Int
    var deletions: Int
    var age: Age
    var url: URL
    /// Head commit the review applies to; Approve pins `commit_id` to it.
    var headSHA: String? = nil
    /// GraphQL node id — used to find out what happened once the request
    /// disappears (resolveReviewRequests).
    var nodeID: String? = nil
    /// Last activity on the PR (used to expire the session's approved filter).
    var updatedAt: Date? = nil

    var meta: String { "#\(number) · \(author.login) · +\(additions) −\(deletions)" }
}

struct Mention: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    /// nil for subjects without a number (e.g. some discussions, releases).
    var number: Int?
    /// Comment excerpt (direct mentions) or the subject title (other activity).
    var comment: String
    /// nil when the row is generic thread activity rather than a direct mention.
    var author: UserRef?
    /// e.g. "mentioned you", "replied to your review", "new activity"
    var context: String
    var age: Age
    var url: URL
    /// GitHub notification thread — opening/dismissing marks it read.
    var threadID: String = ""
    var threadUpdatedAt: Date? = nil
    /// True when the latest comment actually contains "@<login>". Only direct
    /// mentions are quoted as comments and posted as notifications.
    var isDirect: Bool = true

    var title: String { isDirect ? "\u{201C}\(comment)\u{201D}" : comment }
    var meta: String {
        let ref = number.map { "#\($0) · " } ?? ""
        if let author { return "\(ref)\(author.login) \(context)" }
        return "\(ref)\(context)"
    }
}

enum InboxEntry: Identifiable, Hashable {
    case review(ReviewRequest)
    case mention(Mention)

    var id: String {
        switch self {
        case .review(let r): return r.id
        case .mention(let m): return m.id
        }
    }

    var repo: RepoRef {
        switch self {
        case .review(let r): return r.repo
        case .mention(let m): return m.repo
        }
    }

    var age: Age {
        switch self {
        case .review(let r): return r.age
        case .mention(let m): return m.age
        }
    }

    var url: URL {
        switch self {
        case .review(let r): return r.url
        case .mention(let m): return m.url
        }
    }

    var isReview: Bool {
        if case .review = self { return true }
        return false
    }
}

// MARK: - My PRs

enum CIState: Hashable {
    case passing
    case failing(context: String)   // e.g. "lint failed"
    /// Running checks. `pill` overrides the trailing pill text (e.g. "Re-running…");
    /// when nil the pill falls back to merge/review status.
    case running(pill: String?)
    /// The commit has no checks or statuses at all.
    case none
    /// CI couldn't be determined this refresh (fetch failed / not computed).
    /// Never counts as passing, ready or failing.
    case unknown
}

/// Visual style of the trailing status pill on a My PRs row.
enum PillKind: Hashable {
    case neutral    // "Needs review", "Draft" — white 0.55 on white 0.08
    case ready      // "Ready" — success on success 0.12
    case failed     // "lint failed", "Conflicts", "Changes requested" — danger
    case running    // "Re-running…", "Behind base" — attention on attention 0.12
}

/// GitHub's mergeStateStatus.
enum MergeState: String, Hashable, Codable {
    case clean, hasHooks, unstable, blocked, behind, dirty, draft, unknown

    init(graphQL raw: String?) {
        switch raw {
        case "CLEAN": self = .clean
        case "HAS_HOOKS": self = .hasHooks
        case "UNSTABLE": self = .unstable
        case "BLOCKED": self = .blocked
        case "BEHIND": self = .behind
        case "DIRTY": self = .dirty
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }
}

/// GitHub's reviewDecision (nil when the repo doesn't require reviews).
enum ReviewDecision: String, Hashable, Codable {
    case approved, changesRequested, reviewRequired

    init?(graphQL raw: String?) {
        switch raw {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: return nil
        }
    }
}

enum MergeMethod: String, Hashable, Codable {
    case merge, squash, rebase

    /// Confirm-button label for the two-step inline Merge.
    var confirmLabel: String {
        switch self {
        case .merge: return "Merge?"
        case .squash: return "Squash & merge?"
        case .rebase: return "Rebase & merge?"
        }
    }
}

struct MyPR: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    var title: String
    var branch: String
    var ci: CIState
    /// Distinct reviewers whose latest opinionated review is APPROVED.
    var approvals: Int
    var age: Age
    var url: URL
    /// Logins (and team names) review has been requested from.
    var requestedReviewers: [String] = []
    var isDraft = false
    var mergeState: MergeState = .unknown
    var reviewDecision: ReviewDecision? = nil
    /// Some reviewer's latest opinionated review requests changes.
    var changesRequested = false
    /// Merge is pinned to this commit (`sha`); Merge is hidden when nil.
    var headSHA: String? = nil
    /// Repo's merge method for this viewer (already validated as allowed).
    var mergeMethod: MergeMethod? = nil
    /// Actions workflow runs containing a failed job (Re-run targets).
    var failedRunIDs: Set<Int> = []
    /// Web page of the first failing check (one click to the log).
    var failingCheckURL: URL? = nil
    /// Short failure summary for tooltips (check output title / annotations).
    var failingCheckSummary: String? = nil
    var updatedAt: Date? = nil
    /// The viewer can push to the base repo. False for a PR you sent to a
    /// repo you only read (an open-source contribution): merging and
    /// re-running are the maintainers' call there.
    var canWrite = true
    /// False when GitHub errored on this PR's reviews this refresh, so
    /// approvals / changes requested are not trustworthy.
    var reviewStateKnown = true

    var meta: String { "#\(number) · \(branch)" }

    /// Merge offered (two-step) — ready, writable, pinned, method known.
    var canMerge: Bool { isReady && canWrite && headSHA != nil && mergeMethod != nil }

    /// Re-run offered — failing Actions runs in a repo you can write to.
    var canRerun: Bool { isFailing && canWrite && !failedRunIDs.isEmpty }

    var isFailing: Bool {
        if case .failing = ci { return true }
        return false
    }

    var hasConflicts: Bool { mergeState == .dirty }

    /// Blocked on you (owner decision D1): changes requested or conflicts.
    var isBlocked: Bool { !isDraft && (changesRequested || hasConflicts) }

    /// Counts toward the badge / Up next: failing CI or blocked.
    var needsYou: Bool { isFailing || isBlocked }

    /// Ready from GitHub's own state, never a guessed approval count.
    var isReady: Bool {
        guard !isDraft, !changesRequested, headSHA != nil, approvals >= 1 else { return false }
        guard mergeState == .clean || mergeState == .hasHooks else { return false }
        switch ci {
        case .passing, .none: return true
        default: return false
        }
    }

    /// Trailing status pill text.
    var pillText: String {
        switch ci {
        case .failing(let context): return context
        case .running(let pill?): return pill
        default: break
        }
        if isDraft { return "Draft" }
        if hasConflicts { return "Conflicts" }
        if changesRequested { return "Changes requested" }
        if mergeState == .behind { return "Behind base" }
        if isReady { return "Ready" }
        if approvals > 0 { return "\(approvals) approval\(approvals == 1 ? "" : "s")" }
        return "Needs review"
    }

    var pillKind: PillKind {
        switch ci {
        case .failing: return .failed
        case .running(.some): return .running
        default: break
        }
        if isDraft { return .neutral }
        if hasConflicts || changesRequested { return .failed }
        if mergeState == .behind { return .running }
        return isReady ? .ready : .neutral
    }

    /// Row order within a repo group: failing, changes requested, conflicts,
    /// ready, waiting, draft.
    var sortRank: Int {
        if isFailing { return 0 }
        if changesRequested && !isDraft { return 1 }
        if hasConflicts && !isDraft { return 2 }
        if isReady { return 3 }
        if isDraft { return 5 }
        return 4
    }
}

// MARK: - Done (items you've dealt with, last 7 days)

/// How long done items stay listed (owner decision).
let doneWindow: TimeInterval = 7 * 86400

/// What happened to an item that no longer needs you.
enum DoneOutcome: String, Hashable, Codable {
    /// A review you submitted (Inbox).
    case approved, commented, changesRequested
    /// A mention you opened or marked ✓ Done in Queue (Inbox).
    case cleared
    /// A review request that went away without your review (Inbox).
    case resolvedMerged, resolvedClosed, requestRemoved
    /// One of your PRs, merged (My PRs).
    case merged

    var label: String {
        switch self {
        case .approved: return "approved"
        case .commented: return "commented"
        case .changesRequested: return "requested changes"
        case .cleared: return "marked done"
        case .resolvedMerged: return "merged without your review"
        case .resolvedClosed: return "closed"
        case .requestRemoved: return "request removed"
        case .merged: return "merged"
        }
    }

    /// A review you submitted, as opposed to a request that went away.
    var isReview: Bool { self == .approved || self == .commented || self == .changesRequested }
    /// A review that approved or requested changes, not just a comment.
    var isVerdict: Bool { self == .approved || self == .changesRequested }
}

struct DoneItem: Identifiable, Hashable, Codable {
    /// Stable per underlying item, so a review and a "request removed" for
    /// the same PR collapse into one row: "done-pr-<owner/repo>#<n>" for PRs,
    /// "done-thread-<id>" for mention threads.
    var id: String
    var repo: RepoRef
    var number: Int?
    var title: String
    var url: URL
    var doneAt: Date
    var outcome: DoneOutcome
    /// Who did it, when it wasn't you (e.g. merged by alice).
    var actor: String? = nil

    var meta: String {
        let ref = number.map { "#\($0) · " } ?? ""
        return "\(ref)\(what)"
    }

    /// "acme/web#12 · approved": the Done list is flat, so rows name their repo.
    var listMeta: String {
        let ref = repo.fullName + (number.map { "#\($0)" } ?? "")
        return "\(ref) · \(what)"
    }

    /// "merged by alice".
    private var what: String {
        let who = actor.map { " by \($0)" } ?? ""
        return "\(outcome.label)\(who)"
    }

    static func prID(_ repo: RepoRef, _ number: Int) -> String { "done-pr-\(repo.fullName)#\(number)" }
    static func threadID(_ threadID: String) -> String { "done-thread-\(threadID)" }

    /// A mention you opened or marked ✓ Done.
    static func cleared(_ mention: Mention) -> DoneItem {
        DoneItem(id: threadID(mention.threadID), repo: mention.repo, number: mention.number,
                 title: mention.title, url: mention.url, doneAt: Date(), outcome: .cleared)
    }
}

// MARK: - Issues

struct IssueLabel: Hashable, Codable {
    var name: String
}

struct AssignedIssue: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    var title: String
    var assignedAt: Date
    var label: IssueLabel?
    var age: Age
    var url: URL

    var meta: String { "#\(number) · assigned \(Age(date: assignedAt).display) ago" }
}

// MARK: - Stats

struct DayActivity: Identifiable, Hashable {
    var id: Int          // 0…6, oldest → today
    var label: String    // weekday initial, "M" "T" …
    var value: Int       // GitHub contributions that day
    var isToday: Bool
    var isWeekend: Bool
}

/// API-backed numbers for the Stats tab. Review-queue aging and "your PRs
/// waiting" are derived live from the inbox / PR lists instead, so they track
/// this session's approvals.
struct StatsData: Hashable {
    // This week: the last 7 days, from GitHub's contribution data.
    var reviewsThisWeek: Int
    var prsOpenedThisWeek: Int
    var prsMergedThisWeek: Int
    var activity: [DayActivity]
    var streakDays: Int
    // Turnaround + CI.
    /// Median time from opening to first review, over your recently merged PRs.
    var medianFirstReview: TimeInterval?
    var firstReviewSample: Int
    /// Share of conclusive check runs that passed on your open PRs.
    var checksPassRate: Int?
    var mostFailingCheck: String?
    var mostFailingCount: Int
}

/// "45m", "4h 32m", "2d 3h".
func formatDuration(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int(interval / 60))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
    let days = hours / 24
    return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
}

/// Last 7 days ending today, weekday initials, from a date → count lookup.
func lastSevenDays(counts: (Date) -> Int) -> [DayActivity] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let initials = ["S", "M", "T", "W", "T", "F", "S"]   // Calendar weekday 1 = Sunday
    return (0..<7).map { index in
        let day = calendar.date(byAdding: .day, value: index - 6, to: today)!
        let weekday = calendar.component(.weekday, from: day)
        return DayActivity(
            id: index,
            label: initials[weekday - 1],
            value: counts(day),
            isToday: index == 6,
            isWeekend: weekday == 1 || weekday == 7
        )
    }
}

// MARK: - Auth / onboarding

struct DeviceFlowInfo: Hashable {
    var userCode: String          // "7F3A-D21B"
    var verificationURL: URL      // https://github.com/login/device
}

enum AuthState: Hashable {
    case signedOut
    case deviceFlow(DeviceFlowInfo)
    case signedIn(username: String)
}

// MARK: - Tabs

enum PanelTab: String, CaseIterable, Codable {
    case inbox, prs, issues, stats

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .prs: return "My PRs"
        case .issues: return "Issues"
        case .stats: return "Stats"
        }
    }
}

// MARK: - Menu bar icon

enum BadgeStyle: String, CaseIterable, Codable {
    case count, dot, off
}

enum StatusIconState: Hashable {
    case allClear
    /// Count badge; `ciFailing` adds the red dot alongside the number.
    case needsYouCount(Int, ciFailing: Bool)
    case needsYouDot
    case ciFailing          // red pulsing dot, overrides count
    /// Signed out, or signed in but review requests, mentions and your PRs
    /// haven't all loaded yet (AppState.hasLoaded): the glyph alone, dimmed,
    /// so an unknown state never reads as all clear.
    case loading
}

// MARK: - Grouping helper

/// Group list items by repo, sorted by repo full name, preserving item order
/// within each group. The name order keeps groups put between refreshes; a
/// PR changing state or a new comment reorders rows only inside its repo.
func groupByRepo<T>(_ items: [T], repo: (T) -> RepoRef) -> [(repo: RepoRef, items: [T])] {
    var buckets: [RepoRef: [T]] = [:]
    for item in items {
        buckets[repo(item), default: []].append(item)
    }
    return buckets.keys.sorted().map { ($0, buckets[$0]!) }
}
