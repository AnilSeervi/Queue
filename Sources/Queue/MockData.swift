import Foundation

// Fixture data matching the handoff screenshots exactly (screenshots/01–04, 08).
// Used in demo mode (QUEUE_DEMO=1) and as SwiftUI preview data.

enum MockData {
    /// The demo account.
    static let login = "rdejong"
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
                age: Age(date: ago(hours: 2)), url: prURL(itsmCore, 4821),
                headSHA: "3f9c2e1a7b", nodeID: "PR_kwDOdemo4821", updatedAt: ago(minutes: 50))),
            .review(ReviewRequest(
                id: "rr-4809", repo: itsmCore, number: 4809,
                title: "Refactor incident assignment rules",
                author: UserRef(login: "tkole"), additions: 96, deletions: 140,
                age: Age(date: ago(days: 1)), url: prURL(itsmCore, 4809),
                headSHA: "8d41b07c2e", nodeID: "PR_kwDOdemo4809", updatedAt: ago(hours: 7))),
            .mention(Mention(
                id: "m-4790", repo: itsmCore, number: 4790,
                comment: "Went with your suggestion on the retry cap.",
                author: UserRef(login: "jwit"), context: "replied to your review",
                age: Age(date: ago(hours: 4)), url: prURL(itsmCore, 4790),
                threadID: "11004790", threadUpdatedAt: ago(hours: 4))),
            .review(ReviewRequest(
                id: "rr-2210", repo: webClient, number: 2210,
                title: "Migrate request table to virtual scrolling",
                author: UserRef(login: "asmit"), additions: 510, deletions: 388,
                age: Age(date: ago(hours: 5)), url: prURL(webClient, 2210),
                headSHA: "c27e95f310", nodeID: "PR_kwDOdemo2210", updatedAt: ago(hours: 1))),
            .mention(Mention(
                id: "m-2198", repo: webClient, number: 2198,
                comment: "Can you sanity-check the keyboard nav here?",
                author: UserRef(login: "lvdberg"), context: "mentioned you",
                age: Age(date: ago(minutes: 40)), url: prURL(webClient, 2198),
                threadID: "11002198", threadUpdatedAt: ago(minutes: 40))),
            .review(ReviewRequest(
                id: "rr-388", repo: integrations, number: 388,
                title: "Jira sync: handle custom field mapping",
                author: UserRef(login: "pdeboer"), additions: 212, deletions: 40,
                age: Age(date: ago(hours: 1, days: 3)), url: prURL(integrations, 388),
                headSHA: "5a0d6b8e94", nodeID: "PR_kwDOdemo0388", updatedAt: ago(days: 2))),
            // A thread you were mentioned in earlier; the latest comment
            // doesn't mention you, so it's generic activity (no author).
            .mention(Mention(
                id: "m-380", repo: integrations, number: 380,
                comment: "Webhook signing secret rotation",
                author: nil, context: "new activity",
                age: Age(date: ago(hours: 9)),
                url: URL(string: "https://github.com/acme/integrations/pull/380#issuecomment-2210380")!,
                threadID: "11000380", threadUpdatedAt: ago(hours: 9), isDirect: false)),
        ]
    }

    /// One PR in each state: changes requested, running, conflicts, ready,
    /// failing (with Actions runs to re-run), draft. Within a repo the rows
    /// are in MyPR.sortRank order, as the live data source returns them.
    static var prs: [MyPR] {
        [
            MyPR(id: "pr-4835", repo: itsmCore, number: 4835,
                 title: "Batch SLA recalculation for bulk imports", branch: "perf/sla-batch",
                 ci: .passing, approvals: 1,
                 age: Age(date: ago(days: 1)), url: prURL(itsmCore, 4835),
                 mergeState: .blocked, reviewDecision: .changesRequested,
                 changesRequested: true, headSHA: "e8a1f4c09d", mergeMethod: .squash,
                 updatedAt: ago(hours: 2)),
            MyPR(id: "pr-4830", repo: itsmCore, number: 4830,
                 title: "Rate-limit audit log exports", branch: "feat/audit-rate-limit",
                 ci: .running(pill: nil), approvals: 1,
                 age: Age(date: ago(hours: 3)), url: prURL(itsmCore, 4830),
                 requestedReviewers: ["tkole"], mergeState: .blocked,
                 reviewDecision: .reviewRequired, headSHA: "a1b2c3d4e5", mergeMethod: .squash,
                 updatedAt: ago(minutes: 12)),
            MyPR(id: "pr-2219", repo: webClient, number: 2219,
                 title: "Keyboard shortcuts for request triage", branch: "feat/triage-shortcuts",
                 ci: .passing, approvals: 1,
                 age: Age(date: ago(days: 2)), url: prURL(webClient, 2219),
                 mergeState: .dirty, reviewDecision: .approved,
                 headSHA: "0b7d3e2f61", mergeMethod: .squash, updatedAt: ago(hours: 5)),
            MyPR(id: "pr-2215", repo: webClient, number: 2215,
                 title: "Dark mode for request detail pane", branch: "feat/detail-dark-mode",
                 ci: .passing, approvals: 2,
                 age: Age(date: ago(hours: 6)), url: prURL(webClient, 2215),
                 mergeState: .clean, reviewDecision: .approved,
                 headSHA: "d4e5f6a7b8", mergeMethod: .squash, updatedAt: ago(hours: 1)),
            MyPR(id: "pr-391", repo: integrations, number: 391,
                 title: "Retry queue for webhook deliveries", branch: "fix/webhook-retry",
                 ci: .failing(context: "lint failed"), approvals: 0,
                 age: Age(date: ago(hours: 2, days: 2)), url: prURL(integrations, 391),
                 requestedReviewers: ["pdeboer", "asmit"], mergeState: .unstable,
                 reviewDecision: .reviewRequired, headSHA: "b7c8d9e0f1", mergeMethod: .squash,
                 failedRunIDs: [9_000_001],
                 failingCheckURL: URL(string: "https://github.com/acme/integrations/actions/runs/9000001/job/31000001"),
                 failingCheckSummary: "lint: 3 errors in webhook/retry.ts",
                 updatedAt: ago(minutes: 25)),
            MyPR(id: "pr-394", repo: integrations, number: 394,
                 title: "ServiceNow connector scaffolding", branch: "wip/servicenow",
                 ci: .none, approvals: 0,
                 age: Age(date: ago(hours: 20)), url: prURL(integrations, 394),
                 isDraft: true, mergeState: .draft,
                 headSHA: "6c5b4a3928", mergeMethod: .merge, updatedAt: ago(hours: 20)),
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
        let values = [5, 2, 6, 3, 0, 1, 4]
        return StatsData(
            reviewsThisWeek: 12, prsOpenedThisWeek: 4, prsMergedThisWeek: 3,
            activity: lastSevenDays { day in
                let offset = Calendar.current.dateComponents([.day], from: day, to: Calendar.current.startOfDay(for: Date())).day ?? 0
                return values[6 - offset]
            },
            streakDays: 2,
            medianFirstReview: 4 * 3600 + 32 * 60, firstReviewSample: 20,
            checksPassRate: 91, mostFailingCheck: "lint", mostFailingCount: 1
        )
    }

    /// Others' PRs you reviewed this week, newest first: approvals, a
    /// comment-only review, changes requested, across repos and ages.
    static var doneReviews: [DoneItem] {
        func review(_ repo: RepoRef, _ n: Int, _ title: String, _ outcome: DoneOutcome, _ at: Date) -> DoneItem {
            DoneItem(id: DoneItem.prID(repo, n), repo: repo, number: n, title: title,
                     url: prURL(repo, n), doneAt: at, outcome: outcome)
        }
        return [
            review(itsmCore, 4816, "Expose SLA pause reasons in the API", .approved, ago(hours: 3)),
            review(webClient, 2207, "Persist column widths in the request list", .changesRequested, ago(hours: 2, days: 1)),
            review(integrations, 386, "Teams connector: post thread replies as notes", .commented, ago(hours: 5, days: 2)),
            review(itsmCore, 4799, "Business-hours calendar for escalations", .approved, ago(hours: 1, days: 4)),
            review(integrations, 383, "Map Jira priorities to impact levels", .approved, ago(hours: 6, days: 5)),
            review(webClient, 2196, "Lazy-load attachment previews", .commented, ago(hours: 4, days: 6)),
        ]
    }

    /// Your PRs merged this week (the stats' 3), newest first; one merged
    /// by a teammate.
    static var mergedPRs: [DoneItem] {
        [
            DoneItem(id: DoneItem.prID(itsmCore, 4826), repo: itsmCore, number: 4826,
                     title: "Index request events by creation time", url: prURL(itsmCore, 4826),
                     doneAt: ago(hours: 5), outcome: .merged),
            DoneItem(id: DoneItem.prID(webClient, 2212), repo: webClient, number: 2212,
                     title: "Empty state for saved filters", url: prURL(webClient, 2212),
                     doneAt: ago(hours: 3, days: 2), outcome: .merged, actor: "lvdberg"),
            DoneItem(id: DoneItem.prID(integrations, 379), repo: integrations, number: 379,
                     title: "Back off on Slack rate limits", url: prURL(integrations, 379),
                     doneAt: ago(hours: 8, days: 5), outcome: .merged),
        ]
    }

    /// What Queue logged itself (AppState's done log, seeded in demo
    /// mode): a mention you cleared, a request merged before you got to it,
    /// and one withdrawn.
    static var loggedDone: [DoneItem] {
        [
            DoneItem(id: DoneItem.threadID("11002187"), repo: webClient, number: 2187,
                     title: "\u{201C}Does the bulk edit need a feature flag?\u{201D}", url: prURL(webClient, 2187),
                     doneAt: ago(hours: 6), outcome: .cleared),
            DoneItem(id: DoneItem.prID(integrations, 381), repo: integrations, number: 381,
                     title: "Retry Slack file uploads on 502", url: prURL(integrations, 381),
                     doneAt: ago(hours: 2, days: 3), outcome: .resolvedMerged, actor: "pdeboer"),
            DoneItem(id: DoneItem.prID(itsmCore, 4805), repo: itsmCore, number: 4805,
                     title: "Split SLA timers per priority", url: prURL(itsmCore, 4805),
                     doneAt: ago(hours: 20), outcome: .requestRemoved),
        ]
    }

    static var snapshot: Snapshot {
        Snapshot(inbox: inbox, prs: prs, issues: issues, stats: stats,
                 doneReviews: doneReviews, mergedPRs: mergedPRs)
    }
}

/// Demo/preview data source: serves the fixture, pretends writes succeed.
final class MockDataSource: QueueDataSource {
    func refresh() async throws -> Snapshot { MockData.snapshot }
    func approve(_ request: ReviewRequest) async throws {}
    func merge(_ pr: MyPR) async throws {}
    func rerunChecks(_ pr: MyPR) async throws -> Int { max(1, pr.failedRunIDs.count) }
    func markThreadRead(_ threadID: String) async throws {}

    /// A demo request only leaves the inbox through Approve, so each one
    /// resolves as your approval, just now (the live rule: no nodeID, no
    /// answer).
    func resolveReviewRequests(_ requests: [ReviewRequest]) async throws -> [String: DoneItem] {
        var resolved: [String: DoneItem] = [:]
        for request in requests where request.nodeID != nil {
            resolved[request.id] = DoneItem(
                id: DoneItem.prID(request.repo, request.number), repo: request.repo,
                number: request.number, title: request.title, url: request.url,
                doneAt: Date(), outcome: .approved
            )
        }
        return resolved
    }
}

/// Demo auth: fixture device code, authorizes after a short wait.
final class MockAuthProvider: AuthProvider {
    func startDeviceFlow() async throws -> DeviceFlowInfo {
        DeviceFlowInfo(userCode: "7F3A-D21B", verificationURL: URL(string: "https://github.com/login/device")!)
    }
    func waitForSignIn() async throws -> String {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return MockData.login
    }
    func signIn(withToken token: String) async throws -> String {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GitHubError.api("Paste a token first.")
        }
        return MockData.login
    }
}
