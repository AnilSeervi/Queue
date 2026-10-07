import Foundation

// Live QueueDataSource (spec "State Management" → Data fetch): builds a full
// Snapshot from the GitHub REST APIs. Items cover ALL repos (@me-scoped
// searches); settings.watchedRepos only selects the repos on the footer
// main-branch CI strip. Every sub-fetch is guarded
// so one failure degrades to an empty section (or a calm default) instead of
// failing the whole refresh — except 401s, which always throw so the shell can
// treat the session as signed out.

/// Six-hour cache for the turnaround stat (expensive: one request per PR).
private actor TurnaroundCache<Value: Sendable> {
    private var value: Value?
    private var storedAt: Date?

    func fresh() -> Value? {
        guard let storedAt, Date().timeIntervalSince(storedAt) < 6 * 3600 else { return nil }
        return value
    }

    func store(_ new: Value) {
        value = new
        storedAt = Date()
    }
}

/// Remembers the most recent Actions run id per PR id (for rerunChecks).
/// A tiny actor so refresh's concurrent tasks and rerunChecks never race.
private actor RunIDStore {
    private var ids: [String: Int] = [:]
    func replaceAll(_ new: [String: Int]) { ids = new }
    func id(for prID: String) -> Int? { ids[prID] }
}

final class GitHubDataSource: QueueDataSource, @unchecked Sendable {
    private let settings: SettingsStore
    private let client: GitHubClient
    private let runIDs = RunIDStore()
    private let turnaroundCache = TurnaroundCache<Turnaround>()

    init(settings: SettingsStore, client: GitHubClient = GitHubClient()) {
        self.settings = settings
        self.client = client
    }

    // MARK: - QueueDataSource

    func refresh() async throws -> Snapshot {
        // Items (inbox / PRs / issues) always cover ALL repos — the searches
        // are @me-scoped server-side. config.watched only drives the footer
        // main-branch CI strip.
        let config = await currentConfig()

        async let reviewsFetch = guarded([]) { try await self.fetchReviewRequests(config) }
        async let mentionsFetch = guarded([]) { try await self.fetchMentions(config) }
        async let prsFetch = guarded(PRBundle()) { try await self.fetchMyPRs(config) }
        async let issuesFetch = guarded([]) { try await self.fetchAssignedIssues(config) }
        async let weekFetch = guarded(WeekStats()) { try await self.fetchWeek() }
        async let mergedFetch = guarded(0) { try await self.fetchMergedThisWeek() }
        async let turnaroundFetch = guarded(Turnaround()) { try await self.fetchTurnaround(config) }

        let reviews = try await reviewsFetch
        let mentions = try await mentionsFetch
        let bundle = try await prsFetch
        let issues = try await issuesFetch
        let week = try await weekFetch
        let merged = try await mergedFetch
        let turnaround = try await turnaroundFetch

        await runIDs.replaceAll(bundle.runIDs)

        // Reviews first, then mentions; groupByRepo keeps per-repo order.
        let inbox = reviews.map(InboxEntry.review) + mentions.map(InboxEntry.mention)
        let mostFailing = bundle.failingChecks.max { $0.value < $1.value }
        let stats = StatsData(
            reviewsThisWeek: week.reviews,
            prsOpenedThisWeek: week.prsOpened,
            prsMergedThisWeek: merged,
            activity: week.activity,
            streakDays: week.streak,
            medianFirstReview: turnaround.median,
            firstReviewSample: turnaround.sample,
            checksPassRate: bundle.checksTotal > 0
                ? Int((Double(bundle.checksPassed) / Double(bundle.checksTotal) * 100).rounded())
                : nil,
            mostFailingCheck: mostFailing?.key,
            mostFailingCount: mostFailing?.value ?? 0
        )
        return Snapshot(inbox: inbox, prs: bundle.prs, issues: issues, stats: stats, repoCI: [])
    }

    func approve(_ request: ReviewRequest) async throws {
        try await client.rest(
            method: "POST",
            path: "repos/\(request.repo.fullName)/pulls/\(request.number)/reviews",
            body: ["event": "APPROVE"]
        )
    }

    func merge(_ pr: MyPR) async throws {
        try await client.rest(method: "PUT", path: "repos/\(pr.repo.fullName)/pulls/\(pr.number)/merge")
    }

    func rerunChecks(_ pr: MyPR) async throws {
        guard let runID = await runIDs.id(for: pr.id) else { throw GitHubError.noRunID }
        try await client.rest(
            method: "POST",
            path: "repos/\(pr.repo.fullName)/actions/runs/\(runID)/rerun-failed-jobs"
        )
    }

    // MARK: - Config (read on the main actor; SettingsStore is @MainActor)

    private struct Config {
        var login: String            // cached at sign-in; "" when unknown
        var watched: [RepoRef]       // sorted by full name (stable footer order)
    }

    private func currentConfig() async -> Config {
        let watchedNames = await MainActor.run { settings.watchedRepos }
        let watched = watchedNames.compactMap(Self.parseRepo).sorted()
        return Config(
            login: UserDefaults.standard.string(forKey: "githubLogin") ?? "",
            watched: watched
        )
    }

    // MARK: - Search plumbing (256-char q chunking + pagination)

    /// One search/issues query, followed through pagination (page param) up to
    /// `maxPages` pages of 50. Logs when results are clipped at the cap.
    private func searchItems(query: String, maxPages: Int = 3) async throws -> [SearchItem] {
        var items: [SearchItem] = []
        for page in 1...maxPages {
            let results: SearchResults = try await client.get("search/issues", query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "page", value: "\(page)"),
            ])
            items += results.items
            if items.count >= results.totalCount || results.items.count < 50 {
                return items
            }
            if page == maxPages {
                NSLog("Queue: search results clipped at %d of %d for q=%@",
                      items.count, results.totalCount, query)
            }
        }
        return items
    }

    /// All @me searches run unqualified — every repo the user can see.
    private func searchWatched(base: String, config: Config) async throws -> [SearchItem] {
        try await searchItems(query: base)
    }

    // MARK: - Inbox: review requests

    private func fetchReviewRequests(_ config: Config) async throws -> [ReviewRequest] {
        let items = try await searchWatched(base: "is:open is:pr review-requested:@me", config: config)
        // +additions/−deletions come from per-PR detail; concurrent, capped.
        return await mapLimited(items, limit: 10) { item -> ReviewRequest? in
            guard let repo = Self.repoFromAPIURL(item.repositoryUrl) else { return nil }
            var additions = 0, deletions = 0
            let detail: PullDetail? = try? await self.client.get("repos/\(repo.fullName)/pulls/\(item.number)")
            if let detail {
                additions = detail.additions ?? 0
                deletions = detail.deletions ?? 0
            }
            return ReviewRequest(
                id: "rr-\(repo.fullName)#\(item.number)",
                repo: repo,
                number: item.number,
                title: item.title,
                author: UserRef(login: item.user?.login ?? "unknown"),
                additions: additions,
                deletions: deletions,
                age: Age(date: item.createdAt),
                url: URL(string: item.htmlUrl) ?? repo.url
            )
        }
    }

    // MARK: - Inbox: mentions

    private func fetchMentions(_ config: Config) async throws -> [Mention] {
        // /notifications has no server-side reason filter, so a single page can
        // be consumed entirely by other participating notifications (reviews,
        // comments, ci_activity, …) — paginate up to 3 pages before filtering
        // down to mentions in watched repos.
        var threads: [NotificationThread] = []
        for page in 1...3 {
            let batch: [NotificationThread] = try await client.get("notifications", query: [
                URLQueryItem(name: "participating", value: "true"),
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "page", value: "\(page)"),
            ])
            threads += batch
            if batch.count < 50 { break }
            if page == 3 {
                NSLog("Queue: notification scan clipped at %d threads; older mentions may be missed", threads.count)
            }
        }
        let relevant = threads.filter { $0.reason == "mention" }

        return await mapLimited(relevant, limit: 10) { thread -> Mention? in
            guard
                let repo = Self.parseRepo(thread.repository.fullName),
                let number = Self.trailingNumber(thread.subject.url)
            else { return nil }

            let webPath = thread.subject.type == "PullRequest" ? "pull" : "issues"
            // Fallbacks when the comment fetch fails: subject title as the
            // excerpt, generic context, thread timestamps.
            var comment = thread.subject.title
            var author = UserRef(login: "someone")
            var url = URL(string: "https://github.com/\(repo.fullName)/\(webPath)/\(number)") ?? repo.url
            var at = thread.updatedAt ?? Date()

            if let commentURL = thread.subject.latestCommentUrl {
                let fetched: CommentPayload? = try? await self.client.get(commentURL)
                if let fetched {
                    if let body = fetched.body, !body.isEmpty { comment = Self.excerpt(body) }
                    if let login = fetched.user?.login { author = UserRef(login: login) }
                    if let html = fetched.htmlUrl, let u = URL(string: html) { url = u }
                    if let created = fetched.createdAt { at = created }
                }
            }
            return Mention(
                id: "m-\(thread.id)",
                repo: repo,
                number: number,
                comment: comment,
                author: author,
                context: "mentioned you",
                age: Age(date: at),
                url: url
            )
        }
    }

    // MARK: - My PRs

    private struct PRBundle {
        var prs: [MyPR] = []
        var runIDs: [String: Int] = [:]
        var checksPassed = 0
        var checksTotal = 0
        /// Failing check name → number of your open PRs it's failing on.
        var failingChecks: [String: Int] = [:]
    }

    private func fetchMyPRs(_ config: Config) async throws -> PRBundle {
        let items = try await searchWatched(base: "is:open is:pr author:@me", config: config)
        struct PerPR { var pr: MyPR; var runID: Int?; var passed: Int; var total: Int; var failing: Set<String> }

        let perPR = await mapLimited(items, limit: 10) { item -> PerPR? in
            guard let repo = Self.repoFromAPIURL(item.repositoryUrl) else { return nil }
            let prID = "pr-\(repo.fullName)#\(item.number)"

            // Each sub-request degrades independently.
            let detail: PullDetail? = try? await self.client.get("repos/\(repo.fullName)/pulls/\(item.number)")
            let branch = detail?.head.ref ?? "—"

            var ci = CIState.passing
            var runID: Int?
            var passed = 0, total = 0
            var failingNames: Set<String> = []
            if let sha = detail?.head.sha {
                let checks: CheckRunsResponse? = try? await self.client.get(
                    "repos/\(repo.fullName)/commits/\(sha)/check-runs",
                    query: [URLQueryItem(name: "per_page", value: "100")]
                )
                if let runs = checks?.checkRuns {
                    ci = Self.ciState(from: runs)
                    (passed, total) = Self.checkTally(runs)
                    failingNames = Set(runs.filter { Self.failureConclusions.contains($0.conclusion ?? "") }.map(\.name))
                    runID = await self.actionsRunID(repo: repo, sha: sha, runs: runs)
                }
            }

            var approvals = 0
            let reviews: [ReviewPayload]? = try? await self.client.get(
                "repos/\(repo.fullName)/pulls/\(item.number)/reviews",
                query: [URLQueryItem(name: "per_page", value: "100")]
            )
            if let reviews {
                approvals = Set(reviews.filter { $0.state == "APPROVED" }.compactMap { $0.user?.login }).count
            }

            // Heuristic: a repo owned by the signed-in user "looks personal" →
            // 1 required approval; org repos default to 2. (Branch-protection
            // rules aren't cheaply readable with these scopes.)
            let required = repo.owner.lowercased() == config.login.lowercased() && !config.login.isEmpty ? 1 : 2

            let pr = MyPR(
                id: prID,
                repo: repo,
                number: item.number,
                title: item.title,
                branch: branch,
                ci: ci,
                approvals: approvals,
                requiredApprovals: required,
                age: Age(date: item.createdAt),
                url: URL(string: item.htmlUrl) ?? repo.url,
                requestedReviewers: (detail?.requestedReviewers ?? []).map(\.login)
                    + (detail?.requestedTeams ?? []).map(\.name),
                isDraft: detail?.draft ?? item.draft ?? false
            )
            return PerPR(pr: pr, runID: runID, passed: passed, total: total, failing: failingNames)
        }

        var bundle = PRBundle()
        for entry in perPR {
            bundle.prs.append(entry.pr)
            if let runID = entry.runID { bundle.runIDs[entry.pr.id] = runID }
            bundle.checksPassed += entry.passed
            bundle.checksTotal += entry.total
            for name in entry.failing { bundle.failingChecks[name, default: 0] += 1 }
        }
        return bundle
    }

    /// Conclusions that mean "not green — offer Re-run" (cancelled included:
    /// it's conclusive non-success, consistent with checkTally).
    private static let failureConclusions: Set<String> = ["failure", "timed_out", "action_required", "cancelled"]
    /// Statuses that mean a run is still in flight (waiting/pending/requested
    /// cover deployment-protection approval gates).
    private static let inFlightStatuses: Set<String> = ["queued", "in_progress", "waiting", "pending", "requested"]

    /// Any failure → failing("<first failing check name> failed");
    /// any in-flight run → running(pill: nil); else passing.
    private static func ciState(from runs: [CheckRun]) -> CIState {
        if let failing = runs.first(where: { failureConclusions.contains($0.conclusion ?? "") }) {
            return .failing(context: "\(failing.name) failed")
        }
        if runs.contains(where: { inFlightStatuses.contains($0.status) }) {
            return .running(pill: nil)
        }
        return .passing
    }

    /// (passed, total) over conclusive check runs (skipped/neutral excluded).
    private static func checkTally(_ runs: [CheckRun]) -> (Int, Int) {
        let conclusive: Set<String> = ["success", "failure", "timed_out", "action_required", "cancelled"]
        let counted = runs.filter { conclusive.contains($0.conclusion ?? "") }
        return (counted.filter { $0.conclusion == "success" }.count, counted.count)
    }

    /// Actions run id used by rerunChecks: prefer the most recent FAILED check
    /// run's workflow run — rerun-failed-jobs must target the run that actually
    /// contains the failure, not just the newest run on the sha — falling back
    /// to the newest run with a parseable details_url, then one extra query
    /// against the Actions API. Best-effort (nil on failure).
    private func actionsRunID(repo: RepoRef, sha: String, runs: [CheckRun]) async -> Int? {
        let newestFirst = runs.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        for run in newestFirst where Self.failureConclusions.contains(run.conclusion ?? "") {
            if let details = run.detailsUrl, let id = Self.runID(fromDetailsURL: details) {
                return id
            }
        }
        for run in newestFirst {
            if let details = run.detailsUrl, let id = Self.runID(fromDetailsURL: details) {
                return id
            }
        }
        let workflowRuns: WorkflowRuns? = try? await client.get(
            "repos/\(repo.fullName)/actions/runs",
            query: [URLQueryItem(name: "head_sha", value: sha),
                    URLQueryItem(name: "per_page", value: "1")]
        )
        return workflowRuns?.workflowRuns.first?.id
    }

    private static func runID(fromDetailsURL details: String) -> Int? {
        guard let range = details.range(of: "/actions/runs/") else { return nil }
        let digits = details[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Issues

    private func fetchAssignedIssues(_ config: Config) async throws -> [AssignedIssue] {
        let items = try await searchWatched(base: "is:open is:issue assignee:@me", config: config)
        return items.compactMap { item in
            guard let repo = Self.repoFromAPIURL(item.repositoryUrl) else { return nil }
            // Assignment time isn't in search payloads; updated_at approximates
            // it (falls back to created_at).
            let assignedAt = item.updatedAt ?? item.createdAt
            return AssignedIssue(
                id: "is-\(repo.fullName)#\(item.number)",
                repo: repo,
                number: item.number,
                title: item.title,
                assignedAt: assignedAt,
                label: item.labels?.first.map { IssueLabel(name: $0.name) },
                age: Age(date: assignedAt),
                url: URL(string: item.htmlUrl) ?? repo.url
            )
        }
    }

    // MARK: - Footer CI strip

    private func fetchRepoCI(_ config: Config) async throws -> [RepoCIStatus] {
        await mapLimited(config.watched, limit: 10) { repo -> RepoCIStatus? in
            var runs: [CheckRun]? = await self.checkRuns(repo: repo, ref: "main")
            if runs == nil {
                // "main" missing → look up the default branch and retry.
                let detail: RepoDetail? = try? await self.client.get("repos/\(repo.fullName)")
                if let branch = detail?.defaultBranch, branch != "main" {
                    runs = await self.checkRuns(repo: repo, ref: branch)
                }
            }
            guard let runs else { return RepoCIStatus(repo: repo, ok: true, failingFor: nil) }
            let failing = runs.filter { ["failure", "timed_out"].contains($0.conclusion ?? "") }
            guard !failing.isEmpty else { return RepoCIStatus(repo: repo, ok: true, failingFor: nil) }
            let oldestStart = failing.compactMap(\.startedAt).min() ?? Date()
            return RepoCIStatus(repo: repo, ok: false, failingFor: Self.durationString(since: oldestStart))
        }
    }

    private func checkRuns(repo: RepoRef, ref: String) async -> [CheckRun]? {
        let response: CheckRunsResponse? = try? await client.get(
            "repos/\(repo.fullName)/commits/\(ref)/check-runs",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        return response?.checkRuns
    }

    /// "12m" / "3h" / "2d" since a date (footer "· 12m" duration).
    private static func durationString(since date: Date) -> String {
        let minutes = max(1, Int(-date.timeIntervalSinceNow / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Stats

    private struct WeekStats {
        var reviews = 0
        var prsOpened = 0
        var activity = lastSevenDays { _ in 0 }
        var streak = 0
    }

    /// One GraphQL query: the last 7 days' review/PR contribution totals, plus
    /// the year's contribution calendar for the activity bars and streak.
    private func fetchWeek() async throws -> WeekStats {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let query = """
        query($from: DateTime!, $to: DateTime!) {
          viewer {
            week: contributionsCollection(from: $from, to: $to) {
              totalPullRequestReviewContributions
              totalPullRequestContributions
            }
            year: contributionsCollection {
              contributionCalendar {
                weeks { contributionDays { date contributionCount } }
              }
            }
          }
        }
        """
        let data = try await client.graphql(query: query, variables: [
            "from": iso.string(from: now.addingTimeInterval(-7 * 86400)),
            "to": iso.string(from: now),
        ])
        let viewer = data["viewer"] as? [String: Any] ?? [:]
        let week = viewer["week"] as? [String: Any] ?? [:]
        let year = viewer["year"] as? [String: Any] ?? [:]
        let calendar = year["contributionCalendar"] as? [String: Any] ?? [:]
        let weeks = calendar["weeks"] as? [[String: Any]] ?? []

        var byDate: [String: Int] = [:]   // "2026-10-07" → count
        for week in weeks {
            for day in week["contributionDays"] as? [[String: Any]] ?? [] {
                if let date = day["date"] as? String {
                    byDate[date] = day["contributionCount"] as? Int ?? 0
                }
            }
        }
        let dayKey = DateFormatter()
        dayKey.calendar = Calendar(identifier: .gregorian)
        dayKey.dateFormat = "yyyy-MM-dd"
        func count(_ day: Date) -> Int { byDate[dayKey.string(from: day)] ?? 0 }

        // Streak: consecutive active days ending today — or yesterday, so the
        // streak doesn't read 0 every morning before the first contribution.
        let cal = Calendar.current
        var day = cal.startOfDay(for: now)
        if count(day) == 0 { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while count(day) > 0, streak < 366 {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }

        return WeekStats(
            reviews: week["totalPullRequestReviewContributions"] as? Int ?? 0,
            prsOpened: week["totalPullRequestContributions"] as? Int ?? 0,
            activity: lastSevenDays(counts: count),
            streak: streak
        )
    }

    private func fetchMergedThisWeek() async throws -> Int {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86400))
        let results: SearchResults = try await client.get("search/issues", query: [
            URLQueryItem(name: "q", value: "is:pr author:@me is:merged merged:>=\(since)"),
            URLQueryItem(name: "per_page", value: "1"),
        ])
        return results.totalCount
    }

    private struct Turnaround {
        var median: TimeInterval?
        var sample = 0
    }

    /// Median time from opening to the first review by someone else, over
    /// your 20 most recently merged PRs. ~21 requests, so it's computed at
    /// most every 6 hours and served from cache in between.
    private func fetchTurnaround(_ config: Config) async throws -> Turnaround {
        if let cached = await turnaroundCache.fresh() { return cached }
        let results: SearchResults = try await client.get("search/issues", query: [
            URLQueryItem(name: "q", value: "is:pr author:@me is:merged sort:updated-desc"),
            URLQueryItem(name: "per_page", value: "20"),
        ])
        let me = config.login.lowercased()
        let waits = await mapLimited(results.items, limit: 5) { item -> TimeInterval? in
            guard let repo = Self.repoFromAPIURL(item.repositoryUrl) else { return nil }
            let reviews: [ReviewPayload]? = try? await self.client.get(
                "repos/\(repo.fullName)/pulls/\(item.number)/reviews",
                query: [URLQueryItem(name: "per_page", value: "100")]
            )
            let first = reviews?
                .filter { $0.state != "PENDING" && ($0.user?.login.lowercased() ?? me) != me }
                .compactMap(\.submittedAt)
                .min()
            guard let first else { return nil }
            let wait = first.timeIntervalSince(item.createdAt)
            return wait > 0 ? wait : nil
        }
        let sorted = waits.sorted()
        var result = Turnaround(sample: sorted.count)
        // Fewer than 3 reviewed PRs isn't a meaningful median.
        if sorted.count >= 3 {
            let mid = sorted.count / 2
            result.median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
        await turnaroundCache.store(result)
        return result
    }

    // MARK: - Guards & helpers

    /// Non-auth failures degrade to `fallback`; 401 / missing-token always
    /// propagate so the refresh (and UI) can react to a dead session.
    private func guarded<T>(_ fallback: @autoclosure () -> T, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as GitHubError where error.isAuthError {
            throw error
        } catch {
            return fallback()
        }
    }

    /// Order-preserving concurrent map with a concurrency cap (~10): keeps
    /// per-PR detail fan-outs polite to the API. nil results are dropped.
    private func mapLimited<T: Sendable, R: Sendable>(
        _ items: [T],
        limit: Int,
        _ transform: @escaping @Sendable (T) async -> R?
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            func enqueue() {
                let index = next
                let item = items[index]
                group.addTask { (index, await transform(item)) }
                next += 1
            }
            while next < min(limit, items.count) { enqueue() }
            for await (index, value) in group {
                results[index] = value
                if next < items.count { enqueue() }
            }
        }
        return results.compactMap { $0 }
    }

    static func parseRepo(_ fullName: String) -> RepoRef? {
        let parts = fullName.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return RepoRef(owner: String(parts[0]), name: String(parts[1]))
    }

    /// "https://api.github.com/repos/owner/name" → RepoRef.
    private static func repoFromAPIURL(_ url: String) -> RepoRef? {
        guard let range = url.range(of: "/repos/") else { return nil }
        return parseRepo(String(url[range.upperBound...]))
    }

    /// ".../pulls/123" or ".../issues/123" → 123.
    private static func trailingNumber(_ url: String?) -> Int? {
        guard let last = url?.split(separator: "/").last else { return nil }
        return Int(last)
    }

    /// One-line comment excerpt for the mention row title.
    private static func excerpt(_ body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > 140 ? String(collapsed.prefix(139)) + "…" : collapsed
    }

    // MARK: - REST payloads (snake_case via GitHubClient.decoder)

    private struct SearchResults: Decodable {
        var totalCount: Int
        var items: [SearchItem]
    }

    private struct SearchItem: Decodable {
        struct User: Decodable { var login: String }
        struct Label: Decodable { var name: String }
        var number: Int
        var title: String
        var htmlUrl: String
        var repositoryUrl: String
        var createdAt: Date
        var updatedAt: Date?
        var user: User?
        var labels: [Label]?
        var draft: Bool?
    }

    private struct PullDetail: Decodable {
        struct Head: Decodable { var ref: String; var sha: String }
        struct User: Decodable { var login: String }
        struct Team: Decodable { var name: String }
        var additions: Int?
        var deletions: Int?
        var head: Head
        var draft: Bool?
        var requestedReviewers: [User]?
        var requestedTeams: [Team]?
    }

    private struct CheckRunsResponse: Decodable {
        var checkRuns: [CheckRun]
    }

    private struct CheckRun: Decodable {
        var name: String
        var status: String       // queued | in_progress | completed
        var conclusion: String?  // success | failure | neutral | cancelled | timed_out | action_required | skipped | stale
        var startedAt: Date?
        var detailsUrl: String?
    }

    private struct ReviewPayload: Decodable {
        struct User: Decodable { var login: String }
        var user: User?
        var state: String
        var submittedAt: Date?
    }

    private struct NotificationThread: Decodable {
        struct Subject: Decodable {
            var title: String
            var url: String?
            var latestCommentUrl: String?
            var type: String
        }
        struct Repo: Decodable { var fullName: String }
        var id: String
        var reason: String
        var updatedAt: Date?
        var subject: Subject
        var repository: Repo
    }

    private struct CommentPayload: Decodable {
        struct User: Decodable { var login: String }
        var body: String?
        var user: User?
        var htmlUrl: String?
        var createdAt: Date?
    }

    private struct RepoDetail: Decodable {
        var defaultBranch: String
    }

    private struct WorkflowRuns: Decodable {
        struct Run: Decodable { var id: Int }
        var workflowRuns: [Run]
    }
}
