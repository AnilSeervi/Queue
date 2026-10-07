import SwiftUI

// MARK: - Repos

struct RepoRef: Hashable, Codable, Comparable {
    var owner: String
    var name: String

    var fullName: String { "\(owner)/\(name)" }
    var shortName: String { name }
    var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

    static func < (lhs: RepoRef, rhs: RepoRef) -> Bool { lhs.fullName < rhs.fullName }
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

    var meta: String { "#\(number) · \(author.login) · +\(additions) −\(deletions)" }
}

struct Mention: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    /// Comment excerpt shown as the row title, without surrounding quotes.
    var comment: String
    var author: UserRef
    /// e.g. "mentioned you" or "replied to your review"
    var context: String
    var age: Age
    var url: URL

    var title: String { "\u{201C}\(comment)\u{201D}" }
    var meta: String { "#\(number) · \(author.login) \(context)" }
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
}

// MARK: - My PRs

enum CIState: Hashable {
    case passing
    case failing(context: String)   // e.g. "lint failed"
    /// Running checks. `pill` overrides the trailing pill text (e.g. "Re-running…");
    /// when nil the pill falls back to approval status (screenshot 02, row 1).
    case running(pill: String?)
}

/// Visual style of the trailing status pill on a My PRs row.
enum PillKind: Hashable {
    case neutral    // "1 approval needed" — white 0.55 on white 0.08
    case ready      // "Ready · 2/2" — success on success 0.12
    case failed     // "lint failed" — danger on danger 0.12
    case running    // "Re-running…" — attention on attention 0.12
}

struct MyPR: Identifiable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    var title: String
    var branch: String
    var ci: CIState
    var approvals: Int
    var requiredApprovals: Int
    var age: Age
    var url: URL
    /// Logins (and team names) review has been requested from.
    var requestedReviewers: [String] = []
    var isDraft = false

    var meta: String { "#\(number) · \(branch)" }
    var isReady: Bool {
        if case .passing = ci { return approvals >= requiredApprovals }
        return false
    }
    var isFailing: Bool {
        if case .failing = ci { return true }
        return false
    }

    /// Trailing status pill text (spec 1a My PRs).
    var pillText: String {
        switch ci {
        case .failing(let context): return context
        case .running(let pill?): return pill
        default: break
        }
        if approvals >= requiredApprovals { return "Ready · \(approvals)/\(requiredApprovals)" }
        let needed = requiredApprovals - approvals
        return "\(needed) approval\(needed == 1 ? "" : "s") needed"
    }

    var pillKind: PillKind {
        switch ci {
        case .failing: return .failed
        case .running(.some): return .running
        default: return approvals >= requiredApprovals ? .ready : .neutral
        }
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
/// snoozes and this session's approvals.
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

// MARK: - Footer CI strip

struct RepoCIStatus: Identifiable, Hashable {
    var id: String { repo.fullName }
    var repo: RepoRef
    var ok: Bool
    /// How long main has been red, e.g. "12m". Only when failing.
    var failingFor: String?
}

// MARK: - Auth / onboarding

struct DeviceFlowInfo: Hashable {
    var userCode: String          // "7F3A-D21B"
    var verificationURL: URL      // https://github.com/login/device
}

struct WatchableRepo: Identifiable, Hashable {
    var id: String { repo.fullName }
    var repo: RepoRef
    var openPRs: Int
}

enum AuthState: Hashable {
    case signedOut
    case deviceFlow(DeviceFlowInfo)
    case pickingRepos([WatchableRepo])
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
    case snoozed
}

// MARK: - Grouping helper

/// Group list items by repo, sorted by repo full name, preserving item order.
func groupByRepo<T>(_ items: [T], repo: (T) -> RepoRef) -> [(repo: RepoRef, items: [T])] {
    var order: [RepoRef] = []
    var buckets: [RepoRef: [T]] = [:]
    for item in items {
        let r = repo(item)
        if buckets[r] == nil { order.append(r) }
        buckets[r, default: []].append(item)
    }
    return order.map { ($0, buckets[$0]!) }
}
