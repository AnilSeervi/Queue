import Foundation

// Live QueueDataSource (spec "State Management" → Data fetch): builds a full
// Snapshot from four concurrent GraphQL documents (QueueGraphQL: inbox, your
// PRs, stats, done) plus the REST /notifications feed for mentions. Items cover ALL
// repos (@me-scoped searches). Each section succeeds or fails on its own: a
// failure (offline, 403/429, 5xx, a GraphQL error on that alias) lands in
// Snapshot.failed with GitHub's message, and the app keeps that section's
// previous data — never an empty list in its place. 401s always throw so the
// shell can treat the session as signed out.

/// Per-notification-thread cache of the latest comment, reused while the
/// thread's updated_at is unchanged — a mention costs one GET per change, not
/// one per refresh. Entries for threads a refresh no longer returns are dropped.
private actor ThreadCache<Value: Sendable> {
    private var entries: [String: (updatedAt: Date, value: Value)] = [:]

    func value(for threadID: String, updatedAt: Date?) -> Value? {
        guard let updatedAt, let entry = entries[threadID], entry.updatedAt == updatedAt else { return nil }
        return entry.value
    }

    func store(_ value: Value, for threadID: String, updatedAt: Date?) {
        guard let updatedAt else { return }
        entries[threadID] = (updatedAt, value)
    }

    func prune(keeping threadIDs: Set<String>) {
        entries = entries.filter { threadIDs.contains($0.key) }
    }
}

/// Page sizes learned this session: a search whose page timed out (502/504)
/// keeps the halved size, so later refreshes don't wait out the timeout again.
private actor PageSizes {
    private var sizes: [QueueGraphQL.Search: Int] = [:]

    func size(_ search: QueueGraphQL.Search) -> Int {
        sizes[search] ?? QueueGraphQL.pageSize(search)
    }

    /// Halves the size; false once it's at the floor.
    func shrink(_ search: QueueGraphQL.Search) -> Bool {
        let current = size(search)
        guard current > QueueGraphQL.minPageSize else { return false }
        sizes[search] = max(QueueGraphQL.minPageSize, current / 2)
        return true
    }
}

/// Your login as GitHub reported it, for a session that never cached one.
private actor LoginMemo {
    var login: String?

    func remember(_ login: String) { self.login = login }
}

final class GitHubDataSource: QueueDataSource, @unchecked Sendable {
    private typealias Search = QueueGraphQL.Search

    private let settings: SettingsStore
    private let client: GitHubClient
    private let comments = ThreadCache<CommentPayload>()
    private let pageSizes = PageSizes()
    private let askedLogin = LoginMemo()

    init(settings: SettingsStore, client: GitHubClient = GitHubClient()) {
        self.settings = settings
        self.client = client
    }

    // MARK: - QueueDataSource

    func refresh() async throws -> Snapshot {
        let config = currentConfig()
        let now = Date()
        let doneSince = now.addingTimeInterval(-doneWindow)
        client.sso.reset()

        async let inboxDocument = fetchSearches([.reviewRequests, .issues])
        async let prsDocument = fetchSearches([.myPRs])
        async let statsDocument = guarded { try await self.fetchStats() }
        async let doneDocument = fetchDone(config, since: doneSince)
        async let mentionsFetch = guarded { try await self.fetchMentions(config) }

        let inbox = try await inboxDocument
        let mine = try await prsDocument
        let statsParts = try await statsDocument
        let done = try await doneDocument
        let mentionsResult = try await mentionsFetch

        var failed: [SnapshotSection: String] = [:]
        func value<T>(_ result: Result<T, Error>?, _ section: SnapshotSection) -> T? {
            switch result {
            case .success(let value)?:
                return value
            case .failure(let error)?:
                failed[section] = error.localizedDescription
                return nil
            case nil:
                failed[section] = "GitHub returned no data."
                return nil
            }
        }

        let reviews = value(inbox.reviews, .reviews).map { Self.reviewRequests($0) } ?? []
        let issues = value(inbox.issues, .issues).map { Self.issues($0, login: config.login) } ?? []
        let mentions = value(mentionsResult, .mentions) ?? []
        let bundle = value(mine.prs, .prs).map { Self.bundle($0) }
        var stats: StatsData?
        if let parts = value(statsParts, .stats) {
            // The pass rate comes from your PRs' checks: without them the
            // stats would be half-fresh, so they wait for the next refresh.
            if let bundle {
                stats = Self.stats(parts, bundle: bundle)
            } else {
                failed[.stats] = failed[.prs]
            }
        }
        // One section: if either list failed, neither is passed on, so the
        // app keeps both previous lists rather than a half-fresh pair.
        let doneReviews = value(done.results.doneReviews, .done).map { Self.doneReviews($0, since: doneSince) }
        let mergedPRs = value(done.results.mergedPRs, .done).map {
            Self.mergedPRs($0, login: done.login, since: doneSince)
        }
        let doneFresh = failed[.done] == nil

        // Reviews first, then mentions; groupByRepo keeps per-repo order.
        return Snapshot(
            inbox: reviews.map(InboxEntry.review) + mentions.map(InboxEntry.mention),
            prs: bundle?.prs ?? [],
            issues: issues,
            stats: stats,
            failed: failed,
            sso: client.sso.current,
            doneReviews: doneFresh ? doneReviews ?? [] : [],
            mergedPRs: doneFresh ? mergedPRs ?? [] : []
        )
    }

    /// Approve, pinned to the commit the row was fetched at: commits pushed
    /// after the last refresh stay unreviewed.
    func approve(_ request: ReviewRequest) async throws {
        var body: [String: Any] = ["event": "APPROVE"]
        if let sha = request.headSHA { body["commit_id"] = sha }
        try await client.rest(
            method: "POST",
            path: "repos/\(request.repo.fullName)/pulls/\(request.number)/reviews",
            body: body
        )
    }

    /// Merge with the repo's method. `sha` makes the merge conditional: if
    /// anyone pushed after the refresh the row came from, GitHub refuses
    /// with 409 and nothing the user hasn't seen lands.
    func merge(_ pr: MyPR) async throws {
        guard let sha = pr.headSHA else {
            throw GitHubError.api("Queue doesn't know this PR's head commit yet — refresh and retry")
        }
        var body: [String: Any] = ["sha": sha]
        if let method = pr.mergeMethod { body["merge_method"] = method.rawValue }
        do {
            try await client.rest(
                method: "PUT",
                path: "repos/\(pr.repo.fullName)/pulls/\(pr.number)/merge",
                body: body
            )
        } catch GitHubError.http(status: 409, message: _) {
            throw GitHubError.api("New commits since refresh — refresh and retry")
        }
    }

    /// "Re-run failed jobs" on every Actions run in `pr.failedRunIDs`, lowest
    /// id first; returns how many GitHub accepted. One accepted run is a
    /// success. GitHub's reason (for the lowest run) surfaces only when it
    /// refused them all.
    func rerunChecks(_ pr: MyPR) async throws -> Int {
        let runs = pr.failedRunIDs.sorted()
        guard !runs.isEmpty else { throw GitHubError.noRunID }
        var refusals: [Error] = []
        for run in runs {
            do {
                try await client.rest(
                    method: "POST",
                    path: "repos/\(pr.repo.fullName)/actions/runs/\(run)/rerun-failed-jobs"
                )
            } catch {
                refusals.append(error)
            }
        }
        if refusals.count == runs.count, let reason = refusals.first { throw reason }
        return runs.count - refusals.count
    }

    /// Each PR's state by node id, one nodes(ids:) query per
    /// QueueGraphQL.lifecycleBatch. Ids GitHub can't resolve (deleted, no
    /// longer visible, SSO-hidden, not a PR) are omitted. Any failed batch
    /// throws: cleanup just waits for the next round.
    func prLifecycles(_ nodeIDs: [String]) async throws -> [String: PRLifecycle] {
        var seen = Set<String>()
        let ids = nodeIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        var states: [String: PRLifecycle] = [:]
        for start in stride(from: 0, to: ids.count, by: QueueGraphQL.lifecycleBatch) {
            let batch = Array(ids[start..<min(start + QueueGraphQL.lifecycleBatch, ids.count)])
            let (data, errors) = try await client.graphql(
                LifecycleDocument.self,
                query: QueueGraphQL.lifecycleDocument,
                variables: ["ids": batch]
            )
            Self.logDeepErrors(errors)
            guard let nodes = data.nodes else {
                throw GitHubError.api(errors.first?.message ?? "GitHub returned no data.")
            }
            // Index-aligned with the ids.
            for (id, node) in zip(batch, nodes) {
                guard let node = node.value, node.id == id,
                      let state = node.state.flatMap({ PRLifecycle(rawValue: $0.lowercased()) })
                else { continue }
                states[id] = state
            }
        }
        return states
    }

    /// What became of review requests that left the inbox, looked up by
    /// `nodeID` (requests without one are omitted), one nodes(ids:) query
    /// per QueueGraphQL.resolveBatch. Pass each request as last seen: its
    /// `updatedAt` decides which of your reviews answer it. Omitted too:
    /// PRs GitHub still asks you to review (search lag) or couldn't read.
    /// A `doneAt` can predate doneWindow (closed while Queue was off); the
    /// caller filters. Throws auth errors, and the first failure when no
    /// batch got through.
    func resolveReviewRequests(_ requests: [ReviewRequest]) async throws -> [String: DoneItem] {
        let lookups = requests.filter { !($0.nodeID ?? "").isEmpty }
        guard !lookups.isEmpty else { return [:] }
        let login = try await viewerLogin(currentConfig())
        let now = Date()
        var resolved: [String: DoneItem] = [:]
        var failures: [Error] = []
        let starts = Array(stride(from: 0, to: lookups.count, by: QueueGraphQL.resolveBatch))
        for start in starts {
            let batch = Array(lookups[start..<min(start + QueueGraphQL.resolveBatch, lookups.count)])
            do {
                let (data, errors) = try await client.graphql(
                    ResolveDocument.self,
                    query: QueueGraphQL.resolveDocument,
                    variables: ["ids": batch.compactMap(\.nodeID), "login": login]
                )
                Self.logDeepErrors(errors)
                // Index-aligned with the ids; an id GitHub couldn't resolve
                // (deleted, no longer visible) is a null node.
                for (request, node) in zip(batch, data.nodes ?? []) {
                    guard let node = node.value, node.id == request.nodeID,
                          let item = Self.resolution(of: request, node, login: login, now: now)
                    else { continue }
                    resolved[request.id] = item
                }
            } catch let error as GitHubError where error.isAuthError {
                throw error
            } catch {
                failures.append(error)
            }
        }
        if failures.count == starts.count, let first = failures.first { throw first }
        return resolved
    }

    /// Marks the notification thread read on GitHub (205 Reset Content).
    /// The caller records a ReadThreads marker so the row stays hidden even
    /// if this fails or GitHub's feed lags.
    func markThreadRead(_ threadID: String) async throws {
        try await client.rest(method: "PATCH", path: "notifications/threads/\(threadID)")
    }

    // MARK: - Config

    private struct Config {
        var login: String            // cached at sign-in; "" when unknown
    }

    private func currentConfig() -> Config {
        Config(login: UserDefaults.standard.string(forKey: "githubLogin") ?? "")
    }

    /// Your login, for `reviews(author:)` — never "", which would match
    /// everyone's reviews. Sign-in caches it; failing that, GitHub is asked
    /// once per launch.
    private func viewerLogin(_ config: Config) async throws -> String {
        if !config.login.isEmpty { return config.login }
        if let known = await askedLogin.login { return known }
        let (data, _) = try await client.graphql(QueueDocument.self, query: "query { viewer { login } }")
        guard let login = data.viewer?.value?.login, !login.isEmpty else {
            throw GitHubError.api("GitHub didn't say which account this is.")
        }
        await askedLogin.remember(login)
        return login
    }

    // MARK: - GraphQL searches (aliased, paged, error-tolerant)

    /// Nodes of one search across its pages. `errored` names each node's
    /// fields that carried a GraphQL error (GitHub nulled them) — "checks"
    /// there makes CI unknown rather than "no checks".
    private typealias Item<Node> = (node: Node, errored: Set<String>)

    private struct Paged<Node> {
        var items: [Item<Node>] = []
        var total = 0
    }

    private struct SearchResults {
        var reviews: Result<Paged<ReviewRequestPayload>, Error>?
        var prs: Result<Paged<MyPRPayload>, Error>?
        var issues: Result<Paged<AssignedIssuePayload>, Error>?
        var doneReviews: Result<Paged<DoneReviewPayload>, Error>?
        var mergedPRs: Result<Paged<DoneMergePayload>, Error>?

        mutating func fail(_ search: Search, _ error: Error) {
            switch search {
            case .reviewRequests: reviews = .failure(error)
            case .myPRs: prs = .failure(error)
            case .issues: issues = .failure(error)
            case .doneReviews: doneReviews = .failure(error)
            case .mergedPRs: mergedPRs = .failure(error)
            }
        }
    }

    /// Sends `searches` as one document, then follows each search that has
    /// more results with documents repeating only those aliases, up to
    /// QueueGraphQL.maxItems. A page that times out is retried at half the
    /// page size. A search fails alone (and wholly — a partial list would
    /// read as "these items went away") when its alias is null or errored, or
    /// a later page fails. Throws only auth errors. The done searches need
    /// `doneSince` and `login`.
    private func fetchSearches(
        _ searches: [Search],
        doneSince: Date? = nil,
        login: String = ""
    ) async throws -> SearchResults {
        var results = SearchResults()
        var pending = searches
        var cursors: [Search: String] = [:]
        var sizes: [Search: Int] = [:]
        for search in searches { sizes[search] = await pageSizes.size(search) }
        var pages: [Search: Int] = [:]

        while !pending.isEmpty {
            let response: (data: QueueDocument, errors: [GraphQLError])
            do {
                response = try await client.graphql(
                    QueueDocument.self,
                    query: QueueGraphQL.document(searches: pending, extras: false),
                    variables: QueueGraphQL.variables(
                        searches: pending, cursors: cursors, pageSizes: sizes, extras: false,
                        doneSince: doneSince, login: login
                    )
                )
            } catch let error as GitHubError where error.isAuthError {
                throw error
            } catch {
                var shrunk = false
                if let gitHubError = error as? GitHubError, gitHubError.isTimeout {
                    for search in pending where await pageSizes.shrink(search) {
                        sizes[search] = await pageSizes.size(search)
                        shrunk = true
                    }
                }
                if shrunk {
                    NSLog("Queue: %@ timed out; retrying with smaller pages",
                          pending.map(\.rawValue).joined(separator: "+"))
                    continue
                }
                for search in pending { results.fail(search, error) }
                break
            }
            Self.logDeepErrors(response.errors)

            var next: [Search] = []
            for search in pending {
                let pageInfo: (hasNext: Bool, cursor: String?, count: Int, total: Int)?
                switch search {
                case .reviewRequests:
                    pageInfo = Self.absorb(&results.reviews, search, response.data.reviewRequests, response.errors)
                case .myPRs:
                    pageInfo = Self.absorb(&results.prs, search, response.data.myPRs, response.errors)
                case .issues:
                    pageInfo = Self.absorb(&results.issues, search, response.data.issues, response.errors)
                case .doneReviews:
                    pageInfo = Self.absorb(&results.doneReviews, search, response.data.doneReviews, response.errors)
                case .mergedPRs:
                    pageInfo = Self.absorb(&results.mergedPRs, search, response.data.mergedPRs, response.errors)
                }
                guard let pageInfo, pageInfo.hasNext, let cursor = pageInfo.cursor else { continue }
                pages[search, default: 1] += 1
                // Bounded even if GitHub kept answering hasNextPage.
                let maxPages = QueueGraphQL.maxItems / QueueGraphQL.minPageSize
                if pageInfo.count < QueueGraphQL.maxItems, pages[search, default: 1] <= maxPages {
                    cursors[search] = cursor
                    next.append(search)
                } else {
                    NSLog("Queue: %@ clipped at %d of %d results", search.rawValue, pageInfo.count, pageInfo.total)
                }
            }
            pending = next
        }
        return results
    }

    /// Folds one page of `search` into `slot`. Returns the paging state, or
    /// nil once the search has failed.
    private static func absorb<Node>(
        _ slot: inout Result<Paged<Node>, Error>?,
        _ search: Search,
        _ value: Lossy<SearchPage<Node>>?,
        _ errors: [GraphQLError]
    ) -> (hasNext: Bool, cursor: String?, count: Int, total: Int)? {
        if case .failure? = slot { return nil }
        let own = errors.filter { $0.path?.first == .key(search.rawValue) }
        // An error on the alias itself (or its node list) fails the section;
        // one deeper inside a node only nulls part of that node.
        let sectionError = own.first { ($0.path?.count ?? 0) <= 2 }
        guard sectionError == nil, let page = value?.value, let nodes = page.nodes else {
            slot = .failure(GitHubError.api(sectionError?.message ?? own.first?.message ?? "GitHub returned no data."))
            return nil
        }
        var errored: [Int: Set<String>] = [:]
        for error in own {
            guard let path = error.path, path.count > 3,
                  case .index(let index) = path[2], case .key(let field) = path[3] else { continue }
            errored[index, default: []].insert(field)
        }
        var paged = (try? slot?.get()) ?? Paged<Node>()
        for (index, node) in nodes.enumerated() {
            // nil: a node GitHub nulled (e.g. an SSO-protected org) or one
            // that didn't decode — dropped, the rest of the page stands.
            guard let node = node.value else { continue }
            paged.items.append((node, errored[index] ?? []))
        }
        paged.total = page.issueCount ?? paged.items.count
        slot = .success(paged)
        return (page.pageInfo?.hasNextPage ?? false, page.pageInfo?.endCursor, paged.items.count, paged.total)
    }

    private static func logDeepErrors(_ errors: [GraphQLError]) {
        for error in errors where (error.path?.count ?? 0) > 2 {
            NSLog("Queue: GraphQL %@ at %@: %@", error.type ?? "error",
                  (error.path ?? []).map(\.description).joined(separator: "."), error.message)
        }
    }

    /// Drops repeated node ids (results can shift between pages).
    private static func unique<Node>(_ items: [Item<Node>], id: (Node) -> String?) -> [Item<Node>] {
        var seen = Set<String>()
        return items.filter { item in
            guard let key = id(item.node) else { return true }
            return seen.insert(key).inserted
        }
    }

    // MARK: - Inbox: review requests

    private static func reviewRequests(_ paged: Paged<ReviewRequestPayload>) -> [ReviewRequest] {
        unique(paged.items, id: \.id).compactMap { item in
            let node = item.node
            guard
                let number = node.number,
                let title = node.title,
                let repo = node.repo?.fullName.flatMap(parseRepo)
            else { return nil }
            return ReviewRequest(
                id: "rr-\(repo.fullName)#\(number)",
                repo: repo,
                number: number,
                title: title,
                author: UserRef(login: node.author?.login ?? "ghost"),
                additions: node.additions ?? 0,
                deletions: node.deletions ?? 0,
                age: Age(date: node.createdAt ?? Date()),
                url: node.url.flatMap(URL.init(string:)) ?? repo.url,
                headSHA: node.headSHA,
                nodeID: node.id,
                updatedAt: node.updatedAt,
                branchRef: branchRef(
                    repo: repo, number: number, branch: node.branch, crossRepo: node.isCrossRepository,
                    headRepo: node.headRepo, nodeID: node.id, isMine: false
                )
            )
        }
    }

    /// Where the PR's head branch lives. nil when the name is missing, or
    /// when it's in a fork GitHub no longer shows (deleted, unreadable): the
    /// name alone would find the base repo's branch of that name, often
    /// another "main" or "patch-1" altogether.
    private static func branchRef(
        repo: RepoRef,
        number: Int,
        branch: String?,
        crossRepo: Bool?,
        headRepo: RepoPayload?,
        nodeID: String?,
        isMine: Bool
    ) -> BranchRef? {
        guard let branch, !branch.isEmpty else { return nil }
        let head = headRepo?.fullName.flatMap(parseRepo)
        // Without a head repo, only GitHub's word makes it a same-repo PR.
        if head == nil, crossRepo != false { return nil }
        return BranchRef(
            repo: repo,
            number: number,
            branch: branch,
            headRepo: head == repo ? nil : head,
            prNodeID: nodeID,
            isMine: isMine
        )
    }

    // MARK: - Inbox: mentions

    private func fetchMentions(_ config: Config) async throws -> [Mention] {
        // /notifications has no server-side reason filter, so a single page can
        // be consumed entirely by other participating notifications (reviews,
        // comments, ci_activity, …) — paginate up to 3 pages before filtering
        // down to mentions.
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
        var seen = Set<String>()
        threads = threads.filter { seen.insert($0.id).inserted }

        // Threads the user already opened / marked done stay hidden until
        // they have newer activity.
        ReadThreads.prune(fetched: seen)
        let markers = ReadThreads.markers()
        let relevant = threads.filter {
            $0.reason == "mention"
                && !ReadThreads.isRead(threadID: $0.id, updatedAt: $0.updatedAt, markers: markers)
        }
        await comments.prune(keeping: Set(relevant.map(\.id)))

        let login = config.login
        return await mapLimited(relevant, limit: 10) { thread in
            await self.mention(from: thread, login: login)
        }
    }

    /// GitHub keeps a thread's "mention" reason for its whole life, so only a
    /// latest comment that actually says "@login" is quoted as a mention;
    /// anything else is shown honestly as activity on the subject.
    private func mention(from thread: NotificationThread, login: String) async -> Mention? {
        guard let repo = Self.parseRepo(thread.repository.fullName) else { return nil }
        let subject = thread.subject
        let number = ["PullRequest", "Issue", "Discussion"].contains(subject.type)
            ? Self.trailingNumber(subject.url) : nil
        let subjectURL = Self.page(of: subject, in: repo, number: number)
        let latest = await latestComment(of: thread)
        let latestURL = latest?.htmlUrl.flatMap(URL.init(string:))

        if let latest, let body = latest.body,
           login.isEmpty || CommentExcerpt.mentions(body, login: login) {
            let excerpt = CommentExcerpt.make(body)
            return Mention(
                id: "m-\(thread.id)",
                repo: repo,
                number: number,
                comment: excerpt.isEmpty ? subject.title : excerpt,
                author: UserRef(login: latest.user?.login ?? "ghost"),
                context: "mentioned you",
                age: Age(date: latest.createdAt ?? thread.updatedAt ?? Date()),
                url: latestURL ?? subjectURL,
                threadID: thread.id,
                threadUpdatedAt: thread.updatedAt,
                isDirect: true
            )
        }
        return Mention(
            id: "m-\(thread.id)",
            repo: repo,
            number: number,
            comment: subject.title,
            author: nil,
            context: "new activity",
            age: Age(date: thread.updatedAt ?? Date()),
            url: latestURL ?? subjectURL,
            threadID: thread.id,
            threadUpdatedAt: thread.updatedAt,
            isDirect: false
        )
    }

    /// The thread's latest comment, cached until the thread changes. nil when
    /// the subject has none (commits, releases, discussions) or the GET fails.
    private func latestComment(of thread: NotificationThread) async -> CommentPayload? {
        guard let url = thread.subject.latestCommentUrl else { return nil }
        if let cached = await comments.value(for: thread.id, updatedAt: thread.updatedAt) {
            return cached
        }
        guard let fetched: CommentPayload = try? await client.get(url) else { return nil }
        await comments.store(fetched, for: thread.id, updatedAt: thread.updatedAt)
        return fetched
    }

    /// Where a mention row opens when its latest comment has no link: the
    /// subject's own page, built from what the thread names (type, number,
    /// commit sha), else the repo's home page.
    private static func page(of subject: NotificationThread.Subject, in repo: RepoRef, number: Int?) -> URL {
        let home = repo.url.absoluteString
        var path: String?
        switch subject.type {
        case "PullRequest": path = number.map { "pull/\($0)" }
        case "Issue": path = number.map { "issues/\($0)" }
        case "Discussion":
            if let number { path = "discussions/\(number)" } else {
                // Some discussion threads carry no URL; search the repo's
                // discussions for the title instead.
                var search = URLComponents(string: "\(home)/discussions")
                search?.queryItems = [URLQueryItem(name: "discussions_q", value: subject.title)]
                return search?.url ?? repo.url
            }
        case "Release": path = "releases"
        case "Commit": path = subject.url?.split(separator: "/").last.map { "commit/\($0)" }
        default: break
        }
        return path.flatMap { URL(string: "\(home)/\($0)") } ?? repo.url
    }

    // MARK: - My PRs

    private struct PRBundle {
        var prs: [MyPR] = []
        var checksPassed = 0
        var checksTotal = 0
        /// Failing check name → number of your open PRs it's failing on.
        var failingChecks: [String: Int] = [:]
    }

    /// What one rollup entry says about the head commit. Raw values order
    /// the outcomes by weight: a single failure outweighs any number of
    /// passes, a check still running outweighs a pass.
    private enum Outcome: Int, Comparable {
        case neutral, passed, pending, failed

        static func < (lhs: Outcome, rhs: Outcome) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Completed check runs by conclusion. Cancelled, stale and the rest
        /// are failures: none is a pass, and rerun-failed-jobs re-runs them.
        /// A conclusion GitHub adds later reads as neutral.
        static let byConclusion: [String: Outcome] = [
            "SUCCESS": .passed,
            "NEUTRAL": .neutral, "SKIPPED": .neutral,
            "FAILURE": .failed, "TIMED_OUT": .failed, "CANCELLED": .failed,
            "ACTION_REQUIRED": .failed, "STARTUP_FAILURE": .failed, "STALE": .failed,
        ]

        /// Commit-status states, which the rollup's own state shares.
        /// EXPECTED is a required check that hasn't reported yet.
        static let byState: [String: Outcome] = [
            "SUCCESS": .passed, "FAILURE": .failed, "ERROR": .failed,
            "PENDING": .pending, "EXPECTED": .pending,
        ]
    }

    /// One check run or commit status as Queue uses it.
    private struct CheckContext {
        var name: String
        var outcome: Outcome
        var url: URL?
        /// Check-run title or commit-status description.
        var detail: String?
        /// Actions workflow run (check runs only; statuses never re-run).
        var runID: Int?

        /// nil for a rollup entry of a kind neither fragment matched.
        init?(_ check: MyPRPayload.Check) {
            guard let label = check.label else { return nil }
            name = label
            url = check.link.flatMap(URL.init(string:))
            detail = check.note
            if let state = check.state {
                // Commit statuses have one state and no lifecycle; one
                // Queue doesn't know is treated as still waiting.
                outcome = Outcome.byState[state] ?? .pending
                runID = nil
            } else {
                outcome = check.status == "COMPLETED"
                    ? Outcome.byConclusion[check.conclusion ?? ""] ?? .neutral
                    : .pending
                runID = check.suite?.run?.databaseId
                    ?? check.link.flatMap(GitHubDataSource.runID(fromDetailsURL:))
            }
        }
    }

    private static func bundle(_ paged: Paged<MyPRPayload>) -> PRBundle {
        var bundle = PRBundle()
        for item in unique(paged.items, id: \.id) {
            guard let (pr, checks) = myPR(
                item.node,
                ciUnreadable: item.errored.contains("checks"),
                reviewsUnreadable: item.errored.contains("verdicts") || item.errored.contains("reviewDecision")
            ) else { continue }
            bundle.prs.append(pr)
            bundle.checksPassed += checks.filter { $0.outcome == .passed }.count
            bundle.checksTotal += checks.filter { $0.outcome == .passed || $0.outcome == .failed }.count
            for name in Set(checks.filter { $0.outcome == .failed }.map(\.name)) {
                bundle.failingChecks[name, default: 0] += 1
            }
        }
        // Search order is updated-desc; within a repo group the rows read
        // failing, changes requested, conflicts, ready, waiting, draft.
        bundle.prs = bundle.prs.enumerated()
            .sorted { ($0.element.sortRank, $0.offset) < ($1.element.sortRank, $1.offset) }
            .map(\.element)
        return bundle
    }

    private static func myPR(_ node: MyPRPayload, ciUnreadable: Bool, reviewsUnreadable: Bool) -> (MyPR, [CheckContext])? {
        guard
            let number = node.number,
            let title = node.title,
            let repo = node.repo?.fullName.flatMap(parseRepo)
        else { return nil }
        let url = node.url.flatMap(URL.init(string:)) ?? repo.url

        let checks = (node.checks?.contexts?.values ?? []).compactMap(CheckContext.init)
        let ci = ciState(node.checks, unreadable: ciUnreadable, checks: checks)
        let failing = checks.filter { $0.outcome == .failed }
        var failedRunIDs: Set<Int> = []
        var failingURL: URL?
        var failingSummary: String?
        if case .failing = ci {
            failedRunIDs = Set(failing.compactMap(\.runID))
            let checksPage = URL(string: "\(url.absoluteString)/checks")
            failingSummary = summary(failing)
            // Only the first 100 contexts are read. The rollup verdict covers
            // all of them, but past the cut the first failure seen may not be
            // the real one — send the link to the full checks page instead.
            let total = node.checks?.contexts?.totalCount ?? checks.count
            if total > checks.count {
                failingURL = checksPage
                failingSummary = [failingSummary, "Read \(checks.count) of \(total) checks — open the checks page for all of them."]
                    .compactMap { $0 }.joined(separator: "\n")
            } else {
                failingURL = failing.first?.url ?? checksPage
            }
        }

        // Each reviewer's latest approve / request-changes, from people with
        // write access — a later "changes requested" replaces an approval.
        let verdicts = node.verdicts?.values ?? []
        let approvals = Set(verdicts.filter { $0.state == "APPROVED" }.compactMap { $0.author?.login }).count
        let decision = ReviewDecision(graphQL: node.reviewDecision)
        let changesRequested = decision == .changesRequested
            || verdicts.contains { $0.state == "CHANGES_REQUESTED" }
        let requested = (node.pendingReviewers?.values ?? []).compactMap { $0.requestedReviewer?.handle }

        let pr = MyPR(
            id: "pr-\(repo.fullName)#\(number)",
            repo: repo,
            number: number,
            title: title,
            branch: node.branch ?? "—",
            ci: ci,
            approvals: approvals,
            age: Age(date: node.createdAt ?? Date()),
            url: url,
            requestedReviewers: requested,
            isDraft: node.isDraft ?? false,
            mergeState: MergeState(graphQL: node.mergeState),
            reviewDecision: decision,
            changesRequested: changesRequested,
            headSHA: node.headSHA,
            mergeMethod: mergeMethod(node.repo),
            failedRunIDs: failedRunIDs,
            failingCheckURL: failingURL,
            failingCheckSummary: failingSummary,
            updatedAt: node.updatedAt,
            // Unknown role (field missing) keeps the actions available.
            canWrite: node.repo?.permission.map { ["ADMIN", "MAINTAIN", "WRITE"].contains($0) } ?? true,
            reviewStateKnown: !reviewsUnreadable,
            branchRef: branchRef(
                repo: repo, number: number, branch: node.branch, crossRepo: node.isCrossRepository,
                headRepo: node.headRepo, nodeID: node.id, isMine: true
            )
        )
        return (pr, checks)
    }

    /// GitHub's rollup state decides; a state Queue doesn't know is judged
    /// from the entries instead (the heaviest outcome among them). No rollup
    /// means the commit has no checks — unless GitHub withheld it with an
    /// error, which is .unknown and never green.
    private static func ciState(_ rollup: MyPRPayload.Checks?, unreadable: Bool, checks: [CheckContext]) -> CIState {
        guard let rollup else { return unreadable ? .unknown : .none }
        let verdict = rollup.state.flatMap { Outcome.byState[$0] } ?? checks.map(\.outcome).max()
        switch verdict {
        case .failed?: return .failing(context: failingLabel(checks.filter { $0.outcome == .failed }))
        case .pending?: return .running(pill: nil)
        case .passed?: return .passing
        case .neutral?, nil: return .unknown
        }
    }

    /// "lint failed", or "lint +2 failed" when more checks fail.
    private static func failingLabel(_ failing: [CheckContext]) -> String {
        let names = distinct(failing.map(\.name))
        guard let first = names.first else { return "checks failed" }
        return names.count == 1 ? "\(first) failed" : "\(first) +\(names.count - 1) failed"
    }

    /// Tooltip text: the first failure's own words, then the other names.
    private static func summary(_ failing: [CheckContext]) -> String? {
        guard let first = failing.first else { return nil }
        let detail = first.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [detail.flatMap { $0.isEmpty ? nil : "\(first.name): \($0)" } ?? "\(first.name) failed"]
        let others = distinct(failing.dropFirst().map(\.name)).filter { $0 != first.name }
        if !others.isEmpty {
            let shown = others.prefix(4).joined(separator: ", ")
            lines.append("Also failing: \(shown)" + (others.count > 4 ? " +\(others.count - 4) more" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The repo's merge method for this viewer. The viewer's default can
    /// name the user's last-used method even after the repo disabled it, so
    /// fall back to squash, then merge, then rebase among the allowed ones.
    private static func mergeMethod(_ repo: RepoPayload?) -> MergeMethod? {
        guard let repo else { return nil }
        func allowed(_ method: MergeMethod) -> Bool? {
            switch method {
            case .merge: return repo.allowsMerge
            case .squash: return repo.allowsSquash
            case .rebase: return repo.allowsRebase
            }
        }
        let preferred = repo.defaultMergeMethod.flatMap { MergeMethod(rawValue: $0.lowercased()) }
        if let preferred, allowed(preferred) != false { return preferred }
        return [.squash, .merge, .rebase].first { allowed($0) == true } ?? preferred
    }

    /// `https://github.com/o/r/actions/runs/123/job/456` → 123.
    private static func runID(fromDetailsURL details: String) -> Int? {
        guard let range = details.range(of: "/actions/runs/") else { return nil }
        let digits = details[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Issues

    private static func issues(_ paged: Paged<AssignedIssuePayload>, login: String) -> [AssignedIssue] {
        unique(paged.items, id: \.id).compactMap { item in
            let node = item.node
            guard
                let number = node.number,
                let title = node.title,
                let repo = node.repo?.fullName.flatMap(parseRepo)
            else { return nil }
            // When you were (last) assigned; updated_at approximates it when
            // the timeline doesn't say.
            let assignedEvent = (node.assignments?.values ?? [])
                .filter { !login.isEmpty && $0.assignee?.login?.lowercased() == login.lowercased() }
                .compactMap(\.createdAt)
                .max()
            let assignedAt = assignedEvent ?? node.updatedAt ?? node.createdAt ?? Date()
            return AssignedIssue(
                id: "is-\(repo.fullName)#\(number)",
                repo: repo,
                number: number,
                title: title,
                assignedAt: assignedAt,
                label: node.label?.values.first?.name.map { IssueLabel(name: $0) },
                age: Age(date: assignedAt),
                url: node.url.flatMap(URL.init(string:)) ?? repo.url
            )
        }
    }

    // MARK: - Done

    /// How much older than the request's last-seen activity your review may
    /// be and still answer it: the inbox search can list a request for a
    /// moment after your review, which itself moves updatedAt on.
    private static let reviewSlack: TimeInterval = 5 * 60

    /// The done document: others' PRs you reviewed and your merged PRs,
    /// since `since`. Without your login the reviews can't be read, so both
    /// searches fail together.
    private func fetchDone(_ config: Config, since: Date) async throws -> (results: SearchResults, login: String) {
        let login: String
        do {
            login = try await viewerLogin(config)
        } catch let error as GitHubError where error.isAuthError {
            throw error
        } catch {
            var results = SearchResults()
            results.fail(.doneReviews, error)
            results.fail(.mergedPRs, error)
            return (results, "")
        }
        return (try await fetchSearches([.doneReviews, .mergedPRs], doneSince: since, login: login), login)
    }

    /// Others' PRs you reviewed inside the window, newest first. The search
    /// matches PRs updated in the window, so older reviews on PRs with newer
    /// activity are dropped here.
    private static func doneReviews(_ paged: Paged<DoneReviewPayload>, since: Date) -> [DoneItem] {
        unique(paged.items, id: \.id).compactMap { item -> DoneItem? in
            let node = item.node
            guard
                let number = node.number,
                let title = node.title,
                let repo = node.repo?.fullName.flatMap(parseRepo),
                let yours = node.yours,
                let review = yourReview(yours, node.dismissals, since: since)
            else { return nil }
            return DoneItem(
                id: DoneItem.prID(repo, number),
                repo: repo,
                number: number,
                title: title,
                url: node.url.flatMap(URL.init(string:)) ?? repo.url,
                doneAt: review.at,
                outcome: review.outcome
            )
        }
        .sorted { $0.doneAt > $1.doneAt }
    }

    /// Your PRs merged inside the window, newest first; `actor` is whoever
    /// merged when it wasn't you.
    private static func mergedPRs(_ paged: Paged<DoneMergePayload>, login: String, since: Date) -> [DoneItem] {
        unique(paged.items, id: \.id).compactMap { item -> DoneItem? in
            let node = item.node
            guard
                let number = node.number,
                let title = node.title,
                let repo = node.repo?.fullName.flatMap(parseRepo),
                let mergedAt = node.mergedAt,
                mergedAt >= since
            else { return nil }
            return DoneItem(
                id: DoneItem.prID(repo, number),
                repo: repo,
                number: number,
                title: title,
                url: node.url.flatMap(URL.init(string:)) ?? repo.url,
                doneAt: mergedAt,
                outcome: .merged,
                actor: someoneElse(node.mergedBy?.login, login: login)
            )
        }
        .sorted { $0.doneAt > $1.doneAt }
    }

    /// What became of `request` (see resolveReviewRequests): your review
    /// when it answers this request, else merged / closed / no longer asked.
    /// nil while you're still asked, or when your reviews didn't load.
    private static func resolution(
        of request: ReviewRequest,
        _ node: ResolvedPRPayload,
        login: String,
        now: Date
    ) -> DoneItem? {
        guard let yours = node.yours else { return nil }
        func item(_ outcome: DoneOutcome, at date: Date, actor: String? = nil) -> DoneItem {
            DoneItem(
                id: DoneItem.prID(request.repo, request.number),
                repo: request.repo,
                number: request.number,
                title: request.title,
                url: request.url,
                doneAt: date,
                outcome: outcome,
                actor: actor
            )
        }
        // A review from an earlier round, before you were asked again, is
        // older than the request's last-seen activity: not an answer.
        let answersFrom = request.updatedAt.map { $0.addingTimeInterval(-reviewSlack) } ?? .distantPast
        if let review = yourReview(yours, node.dismissals, since: answersFrom) {
            return item(review.outcome, at: review.at)
        }
        switch node.state {
        case "MERGED":
            return item(.resolvedMerged, at: node.mergedAt ?? now, actor: someoneElse(node.mergedBy?.login, login: login))
        case "CLOSED":
            return item(.resolvedClosed, at: node.closedAt ?? now)
        case "OPEN":
            return isAsked(node, login: login) ? nil : item(.requestRemoved, at: now)
        default:
            return nil
        }
    }

    /// GitHub still asks you to review: by login, or through a team you're
    /// on. Only a confirmed request counts — a team whose members can't be
    /// read (no read:org) defers to the inbox search, which already said no.
    private static func isAsked(_ node: ResolvedPRPayload, login: String) -> Bool {
        (node.pendingReviewers?.values ?? []).contains { request in
            guard let reviewer = request.requestedReviewer else { return false }
            if let user = reviewer.login { return sameLogin(user, login) }
            return reviewer.you?.values.contains { sameLogin($0.login, login) } ?? false
        }
    }

    /// Your review since `since` as a done outcome: the latest verdict
    /// (approved, changes requested), else the latest comment. Each reply in
    /// a review thread is a COMMENTED review of its own, so one after your
    /// verdict doesn't turn it into "commented"; and a dismissed verdict
    /// (stale approvals on a new push, say) still reads as what it was.
    private static func yourReview(
        _ reviews: NodeList<YourReviewPayload>,
        _ dismissals: NodeList<DismissalPayload>?,
        since: Date
    ) -> (outcome: DoneOutcome, at: Date)? {
        var dismissed: [String: String] = [:]
        for dismissal in dismissals?.values ?? [] {
            if let id = dismissal.review?.id, let was = dismissal.previousReviewState { dismissed[id] = was }
        }
        let submitted = reviews.values.compactMap { review -> (outcome: DoneOutcome, at: Date)? in
            guard let at = review.submittedAt, at >= since else { return nil }
            // A dismissal past the last 10 is unknown: you weighed in, at least.
            let state = review.state == "DISMISSED"
                ? review.id.flatMap { dismissed[$0] } ?? "COMMENTED"
                : review.state
            switch state {
            case "APPROVED": return (.approved, at)
            case "CHANGES_REQUESTED": return (.changesRequested, at)
            case "COMMENTED": return (.commented, at)
            default: return nil     // PENDING (unsubmitted) or a newer state
            }
        }
        func latest(_ reviews: [(outcome: DoneOutcome, at: Date)]) -> (outcome: DoneOutcome, at: Date)? {
            reviews.max { $0.at < $1.at }
        }
        return latest(submitted.filter { $0.outcome.isVerdict }) ?? latest(submitted)
    }

    /// `actor` unless it's you (or unknown).
    private static func someoneElse(_ actor: String?, login: String) -> String? {
        guard let actor, !actor.isEmpty, !sameLogin(actor, login) else { return nil }
        return actor
    }

    private static func sameLogin(_ a: String?, _ b: String) -> Bool {
        guard let a, !b.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    // MARK: - Stats

    private struct StatsParts {
        var reviews = 0
        var prsOpened = 0
        var activity = lastSevenDays { _ in 0 }
        var streak = 0
        var merged = 0
        var medianFirstReview: TimeInterval?
        var firstReviewSample = 0
    }

    /// The stats document: the last 7 days' review/PR contribution totals,
    /// the year's contribution calendar (activity bars + streak), this week's
    /// merged count and your 20 latest merged PRs' first reviews.
    private func fetchStats() async throws -> StatsParts {
        let (data, errors) = try await client.graphql(
            QueueDocument.self,
            query: QueueGraphQL.document(searches: [], extras: true),
            variables: QueueGraphQL.variables(searches: [], extras: true)
        )
        if let error = errors.first(where: { ($0.path?.count ?? 0) <= 2 }) {
            throw GitHubError.api(error.message)
        }
        guard
            let viewer = data.viewer?.value,
            let merged = data.merged?.value?.issueCount,
            let turnaround = data.turnaround?.value?.nodes
        else { throw GitHubError.api("GitHub returned no stats.") }

        var byDate: [String: Int] = [:]   // "2026-10-07" → count
        for week in viewer.year?.contributionCalendar?.weeks ?? [] {
            for day in week.contributionDays ?? [] {
                if let date = day.date { byDate[date] = day.contributionCount ?? 0 }
            }
        }
        let dayKey = DateFormatter()
        dayKey.calendar = Calendar(identifier: .gregorian)
        dayKey.dateFormat = "yyyy-MM-dd"
        func count(_ day: Date) -> Int { byDate[dayKey.string(from: day)] ?? 0 }

        // Streak: consecutive active days ending today — or yesterday, so the
        // streak doesn't read 0 every morning before the first contribution.
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if count(day) == 0 { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while count(day) > 0, streak < 366 {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }

        // Median time from opening to the first review by someone else.
        let me = viewer.login?.lowercased() ?? ""
        let waits = turnaround.compactMap { $0.value }.compactMap { pr -> TimeInterval? in
            guard let created = pr.createdAt else { return nil }
            let first = (pr.reviews?.values ?? [])
                .filter { $0.state != "PENDING" && ($0.author?.login?.lowercased() ?? me) != me }
                .compactMap(\.submittedAt)
                .min()
            guard let first else { return nil }
            let wait = first.timeIntervalSince(created)
            return wait > 0 ? wait : nil
        }.sorted()
        var median: TimeInterval?
        // Fewer than 3 reviewed PRs isn't a meaningful median.
        if waits.count >= 3 {
            let mid = waits.count / 2
            median = waits.count % 2 == 0 ? (waits[mid - 1] + waits[mid]) / 2 : waits[mid]
        }

        return StatsParts(
            reviews: viewer.week?.totalPullRequestReviewContributions ?? 0,
            prsOpened: viewer.week?.totalPullRequestContributions ?? 0,
            activity: lastSevenDays(counts: count),
            streak: streak,
            merged: merged,
            medianFirstReview: median,
            firstReviewSample: waits.count
        )
    }

    private static func stats(_ parts: StatsParts, bundle: PRBundle) -> StatsData {
        let mostFailing = bundle.failingChecks.max { ($0.value, $1.key) < ($1.value, $0.key) }
        return StatsData(
            reviewsThisWeek: parts.reviews,
            prsOpenedThisWeek: parts.prsOpened,
            prsMergedThisWeek: parts.merged,
            activity: parts.activity,
            streakDays: parts.streak,
            medianFirstReview: parts.medianFirstReview,
            firstReviewSample: parts.firstReviewSample,
            checksPassRate: bundle.checksTotal > 0
                ? Int((Double(bundle.checksPassed) / Double(bundle.checksTotal) * 100).rounded())
                : nil,
            mostFailingCheck: mostFailing?.key,
            mostFailingCount: mostFailing?.value ?? 0
        )
    }

    // MARK: - Guards & helpers

    /// Non-auth failures become the section's `.failure`; 401 / missing-token
    /// always propagate so the refresh (and UI) can react to a dead session.
    private func guarded<T>(_ operation: () async throws -> T) async throws -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch let error as GitHubError where error.isAuthError {
            throw error
        } catch {
            return .failure(error)
        }
    }

    /// Order-preserving concurrent map with a concurrency cap (~10): keeps
    /// per-mention comment fetches polite to the API. nil results are dropped.
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

    private static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func parseRepo(_ fullName: String) -> RepoRef? {
        let parts = fullName.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return RepoRef(owner: String(parts[0]), name: String(parts[1]))
    }

    /// ".../pulls/123" or ".../issues/123" → 123.
    private static func trailingNumber(_ url: String?) -> Int? {
        guard let last = url?.split(separator: "/").last else { return nil }
        return Int(last)
    }

    // MARK: - REST payloads (snake_case via GitHubClient.decoder)

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
}

private extension GraphQLError.PathElement {
    var description: String {
        switch self {
        case .key(let key): return key
        case .index(let index): return "\(index)"
        }
    }
}
