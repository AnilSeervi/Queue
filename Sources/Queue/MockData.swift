import Foundation

// Fixture data matching the handoff screenshots exactly (screenshots/01–04, 08).
// Used in demo mode (QUEUE_DEMO=1) and as SwiftUI preview data.

enum MockData {
    static let org = "acme"
    static let itsmCore = RepoRef(owner: org, name: "itsm-core")
    static let webClient = RepoRef(owner: org, name: "web-client")
    static let integrations = RepoRef(owner: org, name: "integrations")

    private static func ago(minutes: Double = 0, hours: Double = 0, days: Double = 0) -> Date {
        Date().addingTimeInterval(-(minutes * 60 + hours * 3600 + days * 86400))
    }

    private static func prURL(_ repo: RepoRef, _ n: Int) -> URL {
        URL(string: "https://github.com/\(repo.fullName)/pull/\(n)")!
    }
    private static func issueURL(_ repo: RepoRef, _ n: Int) -> URL {
        URL(string: "https://github.com/\(repo.fullName)/issues/\(n)")!
    }

    static var inbox: [InboxEntry] {
        [
            .review(ReviewRequest(
                id: "rr-4821", repo: itsmCore, number: 4821,
                title: "Add SLA breach webhooks to workflow engine",
                author: UserRef(login: "mvdheijden"), additions: 342, deletions: 18,
                age: Age(date: ago(hours: 2)), url: prURL(itsmCore, 4821))),
            .review(ReviewRequest(
                id: "rr-4809", repo: itsmCore, number: 4809,
                title: "Refactor incident assignment rules",
                author: UserRef(login: "tkole"), additions: 96, deletions: 140,
                age: Age(date: ago(days: 1)), url: prURL(itsmCore, 4809))),
            .mention(Mention(
                id: "m-4790", repo: itsmCore, number: 4790,
                comment: "Went with your suggestion on the retry cap.",
                author: UserRef(login: "jwit"), context: "replied to your review",
                age: Age(date: ago(hours: 4)), url: prURL(itsmCore, 4790))),
            .review(ReviewRequest(
                id: "rr-2210", repo: webClient, number: 2210,
                title: "Migrate request table to virtual scrolling",
                author: UserRef(login: "asmit"), additions: 510, deletions: 388,
                age: Age(date: ago(hours: 5)), url: prURL(webClient, 2210))),
            .mention(Mention(
                id: "m-2198", repo: webClient, number: 2198,
                comment: "Can you sanity-check the keyboard nav here?",
                author: UserRef(login: "lvdberg"), context: "mentioned you",
                age: Age(date: ago(minutes: 40)), url: prURL(webClient, 2198))),
            .review(ReviewRequest(
                id: "rr-388", repo: integrations, number: 388,
                title: "Jira sync: handle custom field mapping",
                author: UserRef(login: "pdeboer"), additions: 212, deletions: 40,
                age: Age(date: ago(hours: 1, days: 3)), url: prURL(integrations, 388))),
        ]
    }

    static var prs: [MyPR] {
        [
            MyPR(id: "pr-4830", repo: itsmCore, number: 4830,
                 title: "Rate-limit audit log exports", branch: "feat/audit-rate-limit",
                 ci: .running(pill: nil), approvals: 1, requiredApprovals: 2,
                 age: Age(date: ago(hours: 3)), url: prURL(itsmCore, 4830)),
            MyPR(id: "pr-2215", repo: webClient, number: 2215,
                 title: "Dark mode for request detail pane", branch: "feat/detail-dark-mode",
                 ci: .passing, approvals: 2, requiredApprovals: 2,
                 age: Age(date: ago(hours: 6)), url: prURL(webClient, 2215)),
            MyPR(id: "pr-391", repo: integrations, number: 391,
                 title: "Retry queue for webhook deliveries", branch: "fix/webhook-retry",
                 ci: .failing(context: "lint failed"), approvals: 0, requiredApprovals: 2,
                 age: Age(date: ago(hours: 8)), url: prURL(integrations, 391)),
        ]
    }

    static var issues: [AssignedIssue] {
        [
            AssignedIssue(id: "is-4788", repo: itsmCore, number: 4788,
                          title: "Flaky spec: workflow_timer_spec intermittent timeout",
                          assignedAt: ago(days: 2), label: IssueLabel(name: "ci"),
                          age: Age(date: ago(days: 2)), url: issueURL(itsmCore, 4788)),
            AssignedIssue(id: "is-4712", repo: itsmCore, number: 4712,
                          title: "Audit log export times out above 50k rows",
                          assignedAt: ago(days: 6), label: IssueLabel(name: "perf"),
                          age: Age(date: ago(days: 6)), url: issueURL(itsmCore, 4712)),
            AssignedIssue(id: "is-2190", repo: webClient, number: 2190,
                          title: "Focus ring missing on segmented control",
                          assignedAt: ago(days: 1), label: IssueLabel(name: "a11y"),
                          age: Age(date: ago(days: 1)), url: issueURL(webClient, 2190)),
            AssignedIssue(id: "is-385", repo: integrations, number: 385,
                          title: "Slack app: dedupe channel events on reconnect",
                          assignedAt: ago(days: 4), label: IssueLabel(name: "bug"),
                          age: Age(date: ago(days: 4)), url: issueURL(integrations, 385)),
        ]
    }

    static var stats: StatsData {
        StatsData(
            waitingOnYou: 4, waitingOnOthers: 3,
            reviewTurnaround: "4h 32m", checksPassRate: 91,
            oldestWaiting: "3d", oldestWaitingContext: "Jira sync #388",
            reviewsThisWeek: 12,
            activity: [
                DayActivity(id: 0, label: "M", value: 5, isToday: false, isWeekend: false),
                DayActivity(id: 1, label: "T", value: 2, isToday: false, isWeekend: false),
                DayActivity(id: 2, label: "W", value: 6, isToday: false, isWeekend: false),
                DayActivity(id: 3, label: "T", value: 3, isToday: false, isWeekend: false),
                DayActivity(id: 4, label: "F", value: 5, isToday: true, isWeekend: false),
                DayActivity(id: 5, label: "S", value: 0, isToday: false, isWeekend: true),
                DayActivity(id: 6, label: "S", value: 0, isToday: false, isWeekend: true),
            ])
    }

    static var repoCI: [RepoCIStatus] {
        [
            RepoCIStatus(repo: itsmCore, ok: true, failingFor: nil),
            RepoCIStatus(repo: webClient, ok: true, failingFor: nil),
            RepoCIStatus(repo: integrations, ok: false, failingFor: "12m"),
        ]
    }

    static var watchableRepos: [WatchableRepo] {
        [
            WatchableRepo(repo: itsmCore, openPRs: 62),
            WatchableRepo(repo: webClient, openPRs: 38),
            WatchableRepo(repo: integrations, openPRs: 14),
            WatchableRepo(repo: RepoRef(owner: org, name: "mobile"), openPRs: 9),
            WatchableRepo(repo: RepoRef(owner: org, name: "docs"), openPRs: 3),
        ]
    }

    static var snapshot: Snapshot {
        Snapshot(inbox: inbox, prs: prs, issues: issues, stats: stats, repoCI: repoCI)
    }
}

/// Demo/preview data source: serves the fixture, pretends writes succeed.
final class MockDataSource: QueueDataSource {
    func refresh() async throws -> Snapshot { MockData.snapshot }
    func approve(_ request: ReviewRequest) async throws {}
    func merge(_ pr: MyPR) async throws {}
    func rerunChecks(_ pr: MyPR) async throws {}
}

/// Demo auth: fixture device code, authorizes after a short wait.
final class MockAuthProvider: AuthProvider {
    func startDeviceFlow() async throws -> DeviceFlowInfo {
        DeviceFlowInfo(userCode: "7F3A-D21B", verificationURL: URL(string: "https://github.com/login/device")!)
    }
    func waitForSignIn() async throws -> String {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return "rdejong"
    }
    func fetchWatchableRepos() async throws -> [WatchableRepo] { MockData.watchableRepos }
    func signIn(withToken token: String) async throws -> String {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitHubError.api("Paste a token first.")
        }
        return "rdejong"
    }
}
