import Foundation

// The aliased GraphQL documents a refresh sends, plus the payloads they
// decode into. Everything the old REST fan-out needed comes from three
// documents sent concurrently: the inbox (review requests + assigned issues),
// your PRs, and the stats extras (viewer contributions, merged count,
// turnaround sample). GitHub resolves the aliases of one document serially,
// so a single document for a busy account ran ~8s against GitHub's 10s
// timeout (a 502 would have failed every section at once); split, the slowest
// takes ~4s and a timeout costs only its own sections. A fourth, the done
// document (your reviews and merged PRs of the last week), runs alongside:
// ~1.4s, so it adds no wait, and its own point keeps the stats document ~0.5s
// faster than carrying it would. 1 point per document, ~4 a refresh.
// Searches with more results are followed up with documents that repeat only
// those aliases, `after` their cursor, up to `maxItems`.
//
// Fields are aliased to the names of the Queue models they fill (`repo`,
// `branch`, `headSHA`, `checks`, …), so a payload reads like the model it
// becomes. Foundation-only on purpose: the document text can be compiled
// standalone and checked against the live schema with `gh api graphql`.

enum QueueGraphQL {
    /// Search aliases that page. Raw values are the aliases in the document
    /// (no underscores: the shared decoder converts snake_case keys).
    enum Search: String, CaseIterable {
        case reviewRequests, myPRs, issues
        /// The done document: others' PRs you reviewed, your merged PRs.
        case doneReviews, mergedPRs
    }

    /// The per-search cap (results past it are logged as clipped).
    static let maxItems = 150

    /// My PRs carry mergeStateStatus and every check context, which GitHub
    /// computes per node (~0.35s each in mdn/content, ~0.7s in vercel/next.js),
    /// so they page small to stay inside the 10s timeout. A page that still
    /// times out is retried at half the size, down to `minPageSize`.
    static func pageSize(_ search: Search) -> Int {
        search == .myPRs ? 10 : 50
    }

    static let minPageSize = 5

    /// The search qualifiers: every repo you can see (no org: scoping),
    /// archived repos excluded, an explicit sort so the cap cuts predictably.
    /// `doneSince` starts the done searches' window (now − doneWindow).
    static func searchQuery(_ search: Search, doneSince: Date) -> String {
        let since = ISO8601DateFormatter().string(from: doneSince)
        switch search {
        case .reviewRequests: return "is:open is:pr review-requested:@me archived:false sort:created-asc"
        case .myPRs: return "is:open is:pr author:@me archived:false sort:updated-desc"
        case .issues: return "is:open is:issue assignee:@me archived:false sort:created-asc"
        // Search can't filter by when you reviewed, only by when the PR last
        // changed (your review is a change); the rows' own reviews decide.
        case .doneReviews: return "is:pr reviewed-by:@me -author:@me archived:false updated:>=\(since) sort:updated-desc"
        // The stats tab's merged count, listed.
        case .mergedPRs: return mergedQuery(since: since) + " sort:updated-desc"
        }
    }

    static func mergedQuery(since: String) -> String { "is:pr author:@me is:merged merged:>=\(since)" }
    static let turnaroundQuery = "is:pr author:@me is:merged sort:updated-desc"

    /// Builds a document for `searches`; `extras` adds the stats aliases
    /// (viewer, merged, turnaround). GraphQL rejects unused variables and
    /// fragments, so only the requested aliases declare theirs.
    static func document(searches: [Search], extras: Bool) -> String {
        var variables: [String] = []
        var fields: [String] = ["rateLimit { cost remaining }"]
        // reviews(author:) takes a login; @me works only in search queries.
        if searches.contains(.doneReviews) { variables.append("$login: String!") }
        for search in searches {
            let name = search.rawValue
            variables += ["$\(name)Q: String!", "$\(name)First: Int!", "$\(name)After: String"]
            fields.append("""
            \(name): search(type: ISSUE, query: $\(name)Q, first: $\(name)First, after: $\(name)After) {
              issueCount
              pageInfo { hasNextPage endCursor }
              nodes { \(row(search)) }
            }
            """)
        }
        if extras {
            variables += ["$mergedQ: String!", "$turnaroundQ: String!", "$from: DateTime!", "$to: DateTime!"]
            fields.append(viewerSelection)
            fields.append("merged: search(type: ISSUE, query: $mergedQ, first: 0) { issueCount }")
            fields.append(turnaroundSelection)
        }
        var text = "query Queue(\(variables.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}"
        if searches.contains(.myPRs) { text += "\n" + checkFragments }
        return text
    }

    /// Variables for `document(searches:extras:)`. `cursors` holds the
    /// `after` value of each search being continued; `pageSizes` overrides
    /// `pageSize(_:)`. The done searches need `doneSince` (they find
    /// nothing without it) and your `login`; keep both fixed across pages.
    static func variables(
        searches: [Search],
        cursors: [Search: String] = [:],
        pageSizes: [Search: Int] = [:],
        extras: Bool,
        now: Date = Date(),
        doneSince: Date? = nil,
        login: String = ""
    ) -> [String: Any] {
        var variables: [String: Any] = [:]
        if searches.contains(.doneReviews) { variables["login"] = login }
        for search in searches {
            variables["\(search.rawValue)Q"] = searchQuery(search, doneSince: doneSince ?? now)
            variables["\(search.rawValue)First"] = pageSizes[search] ?? pageSize(search)
            if let cursor = cursors[search] { variables["\(search.rawValue)After"] = cursor }
        }
        if extras {
            let iso = ISO8601DateFormatter()
            let weekAgo = now.addingTimeInterval(-7 * 86400)
            variables["mergedQ"] = mergedQuery(since: iso.string(from: weekAgo))
            variables["turnaroundQ"] = turnaroundQuery
            variables["from"] = iso.string(from: weekAgo)
            variables["to"] = iso.string(from: now)
        }
        return variables
    }

    /// One search result, shaped like the Queue row it becomes.
    private static func row(_ search: Search) -> String {
        switch search {
        case .reviewRequests:
            return """
            ... on PullRequest {
                id number title url createdAt updatedAt additions deletions
                headSHA: headRefOid
                author { login }
                repo: repository { fullName: nameWithOwner }
                \(headBranch)
                \(stack)
              }
            """
        case .myPRs:
            // `checks` rolls up everything reported on the head commit:
            // Checks API runs and the older commit-status API, which the
            // QueueCheck / QueueStatus fragments give one shape. Requested
            // reviewers are users, bots, mannequins or teams; each
            // contributes one `handle`.
            return """
            ... on PullRequest {
                id number title url createdAt updatedAt isDraft reviewDecision
                \(headBranch)
                \(stack)
                headSHA: headRefOid
                mergeState: mergeStateStatus
                repo: repository {
                  fullName: nameWithOwner
                  defaultMergeMethod: viewerDefaultMergeMethod
                  allowsMerge: mergeCommitAllowed
                  allowsSquash: squashMergeAllowed
                  allowsRebase: rebaseMergeAllowed
                  permission: viewerPermission
                }
                verdicts: latestOpinionatedReviews(first: 20, writersOnly: true) { nodes { state author { login } } }
                pendingReviewers: reviewRequests(first: 20) {
                  nodes {
                    requestedReviewer {
                      ... on User { handle: login }
                      ... on Bot { handle: login }
                      ... on Mannequin { handle: login }
                      ... on Team { handle: name }
                    }
                  }
                }
                checks: statusCheckRollup {
                  state
                  contexts(first: 100) { totalCount nodes { ...QueueCheck ...QueueStatus } }
                }
              }
            """
        case .issues:
            // The latest assignment event dates "assigned 2d ago" for real.
            return """
            ... on Issue {
                id number title url createdAt updatedAt
                repo: repository { fullName: nameWithOwner }
                label: labels(first: 1) { nodes { name } }
                assignments: timelineItems(itemTypes: [ASSIGNED_EVENT], last: 10) {
                  nodes {
                    ... on AssignedEvent {
                      createdAt
                      assignee {
                        ... on User { login }
                        ... on Bot { login }
                        ... on Mannequin { login }
                      }
                    }
                  }
                }
              }
            """
        case .doneReviews:
            // Only your reviews, latest last; PENDING (unsubmitted) never.
            return """
            ... on PullRequest {
                id number title url
                repo: repository { fullName: nameWithOwner }
                \(yourReviews)
              }
            """
        case .mergedPRs:
            return """
            ... on PullRequest {
                id number title url mergedAt
                mergedBy { login }
                repo: repository { fullName: nameWithOwner }
              }
            """
        }
    }

    /// Where a PR's head branch lives (Copy branch, open in editor). The head
    /// repo is null when the fork was deleted or can't be read, which only
    /// `isCrossRepository` tells apart from a same-repo PR. Scalars and a
    /// single object, no connection: the documents stay at 1 point. The head
    /// repo is the only part with a measurable price, each fork's repository
    /// loading: ~0.5s on a 50-node page of mdn/content's PRs, lost in the
    /// noise on a 10-node My PRs page.
    private static let headBranch = """
    branch: headRefName
        isCrossRepository
        headRepo: headRepository { fullName: nameWithOwner }
    """

    /// The PR's stack (stacked pull requests), when it's in one: null for
    /// most PRs, and on repos without stacks.
    private static let stack = """
    stack {
          id number size baseRefName
          entries(first: 25) { nodes { position pullRequest { id number headRefName state } } }
        }
        stackEntry { position }
    """

    /// Your latest submitted reviews on a PR, and its latest dismissals (a
    /// dismissed review reads DISMISSED; the event keeps the verdict it
    /// was). A connection's own `first` or `last` doesn't add cost (its
    /// parent's size does), so 10 is free headroom: each reply you post in a
    /// review thread is a COMMENTED review of its own. The dismissals keep
    /// the done document at 1 point and add 1 to a full resolve batch.
    private static let yourReviews = """
    yours: reviews(author: $login, last: 10, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
          nodes { id state submittedAt }
        }
        dismissals: timelineItems(itemTypes: [REVIEW_DISMISSED_EVENT], last: 10) {
          nodes { ... on ReviewDismissedEvent { previousReviewState review { id } } }
        }
    """

    /// Most review requests `resolveDocument` looks up at once.
    static let resolveBatch = 50

    /// What became of review requests that left the inbox, by PR node id:
    /// the PR's state, who merged it, your latest review, and whether you're
    /// still asked — by login, or through a team you're on. The usual
    /// handful of ids costs 1 point (~1s); a full batch of 50, 7 (mostly the
    /// team lookups, 50 × 10 of them). Ids GitHub can't resolve come back as null
    /// nodes with a NOT_FOUND error; the rest of the batch stands.
    static let resolveDocument = """
    query QueueResolve($ids: [ID!]!, $login: String!) {
      rateLimit { cost remaining }
      nodes(ids: $ids) {
        ... on PullRequest {
          id state mergedAt closedAt
          mergedBy { login }
          pendingReviewers: reviewRequests(first: 10) {
            nodes {
              requestedReviewer {
                ... on User { login }
                ... on Team { you: members(query: $login, first: 10) { nodes { login } } }
              }
            }
          }
          \(yourReviews)
        }
      }
    }
    """

    /// Most PRs `lifecycleDocument` looks up at once.
    static let lifecycleBatch = 50

    /// Open / merged / closed by PR node id, for worktree cleanup: 1 point
    /// for a full batch. Ids GitHub can't resolve come back as null nodes
    /// with a NOT_FOUND error; ids of other kinds of node, as `{}`.
    static let lifecycleDocument = """
    query QueueLifecycles($ids: [ID!]!) {
      rateLimit { cost remaining }
      nodes(ids: $ids) { ... on PullRequest { id state } }
    }
    """

    /// A check run and a commit status answer under the same keys (`label`,
    /// `link`, `note`); `state` is present only on statuses, `status` and
    /// `conclusion` only on check runs. `run` names the Actions workflow run
    /// a failure re-runs.
    private static let checkFragments = """
    fragment QueueCheck on CheckRun {
      label: name
      link: detailsUrl
      note: title
      status
      conclusion
      suite: checkSuite { run: workflowRun { databaseId } }
    }
    fragment QueueStatus on StatusContext {
      label: context
      link: targetUrl
      note: description
      state
    }
    """

    private static let viewerSelection = """
    viewer {
      login
      week: contributionsCollection(from: $from, to: $to) {
        totalPullRequestReviewContributions
        totalPullRequestContributions
      }
      year: contributionsCollection {
        contributionCalendar { weeks { contributionDays { date contributionCount } } }
      }
    }
    """

    /// Your 20 most recently merged PRs with their first reviews — the
    /// "median time to first review" sample.
    private static let turnaroundSelection = """
    turnaround: search(type: ISSUE, query: $turnaroundQ, first: 20) {
      nodes {
        ... on PullRequest {
          createdAt
          reviews(first: 10) { nodes { state submittedAt author { login } } }
        }
      }
    }
    """
}

// MARK: - Payloads

/// Decodes `T`, or holds nil when that subtree is null or doesn't match —
/// one odd node (or a node GitHub nulled with an error) never fails the
/// whole section.
struct Lossy<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Top-level `data` of any Queue document; aliases a page didn't request
/// decode as nil.
struct QueueDocument: Decodable {
    var reviewRequests: Lossy<SearchPage<ReviewRequestPayload>>?
    var myPRs: Lossy<SearchPage<MyPRPayload>>?
    var issues: Lossy<SearchPage<AssignedIssuePayload>>?
    var doneReviews: Lossy<SearchPage<DoneReviewPayload>>?
    var mergedPRs: Lossy<SearchPage<DoneMergePayload>>?
    var viewer: Lossy<ViewerPayload>?
    var merged: Lossy<MatchCount>?
    var turnaround: Lossy<SearchPage<MergedPRPayload>>?
    var rateLimit: RateLimitPayload?
}

/// `data` of `QueueGraphQL.resolveDocument`.
struct ResolveDocument: Decodable {
    var nodes: [Lossy<ResolvedPRPayload>]?
    var rateLimit: RateLimitPayload?
}

/// `data` of `QueueGraphQL.lifecycleDocument`.
struct LifecycleDocument: Decodable {
    struct PR: Decodable {
        var id: String?
        var state: String?          // OPEN | CLOSED | MERGED
    }
    var nodes: [Lossy<PR>]?
    var rateLimit: RateLimitPayload?
}

struct RateLimitPayload: Decodable {
    var cost: Int?
    var remaining: Int?
}

struct MatchCount: Decodable {
    var issueCount: Int?
}

/// Any actor that has a login (user, bot, mannequin).
struct LoginPayload: Decodable {
    var login: String?
}

/// A connection's `nodes`, index-aligned with GraphQL error paths
/// (…, "nodes", i, …).
struct NodeList<Node: Decodable>: Decodable {
    var nodes: [Lossy<Node>]?
    /// Size of the whole connection, when asked for; more than `nodes` holds
    /// means the list was cut off.
    var totalCount: Int?

    var values: [Node] { (nodes ?? []).compactMap(\.value) }
}

/// One page of a search. An issue that turns up in a PR search matches none
/// of the inline fragments and arrives as `{}`; hence every payload field is
/// optional.
struct SearchPage<Node: Decodable>: Decodable {
    struct PageInfo: Decodable {
        var hasNextPage: Bool?
        var endCursor: String?
    }
    var issueCount: Int?
    var pageInfo: PageInfo?
    var nodes: [Lossy<Node>]?
}

struct RepoPayload: Decodable {
    var fullName: String?
    /// MERGE | SQUASH | REBASE — can name a method the repo has since disabled.
    var defaultMergeMethod: String?
    var allowsMerge: Bool?
    var allowsSquash: Bool?
    var allowsRebase: Bool?
    /// The viewer's role: ADMIN | MAINTAIN | WRITE | TRIAGE | READ (My PRs only).
    var permission: String?
}

/// A PR's stack and its place in it.
struct StackPayload: Decodable {
    struct Entry: Decodable {
        struct Member: Decodable {
            var id: String?
            var number: Int?
            var headRefName: String?
            var state: String?      // OPEN | CLOSED | MERGED
        }
        var position: Int?
        var pullRequest: Member?
    }
    var id: String?
    var number: Int?
    var size: Int?
    var baseRefName: String?
    var entries: NodeList<Entry>?
}

struct StackEntryPayload: Decodable {
    var position: Int?
}

struct ReviewRequestPayload: Decodable {
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var createdAt: Date?
    var updatedAt: Date?
    var additions: Int?
    var deletions: Int?
    var headSHA: String?
    var author: LoginPayload?
    var repo: RepoPayload?
    var branch: String?
    var isCrossRepository: Bool?
    var headRepo: RepoPayload?
    var stack: StackPayload?
    var stackEntry: StackEntryPayload?
}

struct MyPRPayload: Decodable {
    /// A reviewer's latest approve / request-changes.
    struct Verdict: Decodable {
        var state: String?          // APPROVED | CHANGES_REQUESTED | …
        var author: LoginPayload?
    }
    struct PendingReviewer: Decodable {
        struct Reviewer: Decodable {
            var handle: String?     // login, or a team's name
        }
        var requestedReviewer: Reviewer?
    }
    /// One entry of the rollup: a check run or a commit status (QueueCheck /
    /// QueueStatus in the document).
    struct Check: Decodable {
        struct Suite: Decodable {
            struct Run: Decodable { var databaseId: Int? }
            var run: Run?
        }
        var label: String?
        var link: String?
        /// Check-run title or commit-status description.
        var note: String?
        var status: String?         // check runs: QUEUED | IN_PROGRESS | COMPLETED | WAITING | …
        var conclusion: String?     // check runs: SUCCESS | FAILURE | NEUTRAL | …
        var state: String?          // statuses: ERROR | EXPECTED | FAILURE | PENDING | SUCCESS
        var suite: Suite?

        var isCommitStatus: Bool { state != nil }
    }
    struct Checks: Decodable {
        var state: String?          // the rollup: ERROR | EXPECTED | FAILURE | PENDING | SUCCESS
        var contexts: NodeList<Check>?
    }

    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var createdAt: Date?
    var updatedAt: Date?
    var isDraft: Bool?
    var reviewDecision: String?
    var branch: String?
    var isCrossRepository: Bool?
    /// The branch's repo (the fork, for fork PRs); null when the fork was
    /// deleted or can't be read.
    var headRepo: RepoPayload?
    var headSHA: String?
    var mergeState: String?
    var repo: RepoPayload?
    var verdicts: NodeList<Verdict>?
    var pendingReviewers: NodeList<PendingReviewer>?
    var stack: StackPayload?
    var stackEntry: StackEntryPayload?
    /// nil when the head commit has no checks or statuses — or when GitHub
    /// nulled it with an error, which the data source tells apart.
    var checks: Checks?
}

struct AssignedIssuePayload: Decodable {
    struct Label: Decodable { var name: String? }
    struct Assignment: Decodable {
        var createdAt: Date?
        var assignee: LoginPayload?
    }
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var createdAt: Date?
    var updatedAt: Date?
    var repo: RepoPayload?
    var label: NodeList<Label>?
    var assignments: NodeList<Assignment>?
}

struct ViewerPayload: Decodable {
    struct Week: Decodable {
        var totalPullRequestReviewContributions: Int?
        var totalPullRequestContributions: Int?
    }
    struct Year: Decodable {
        struct Calendar: Decodable {
            struct WeekDays: Decodable {
                struct Day: Decodable {
                    var date: String?           // "2026-10-07"
                    var contributionCount: Int?
                }
                var contributionDays: [Day]?
            }
            var weeks: [WeekDays]?
        }
        var contributionCalendar: Calendar?
    }
    var login: String?
    var week: Week?
    var year: Year?
}

struct MergedPRPayload: Decodable {
    struct Review: Decodable {
        var state: String?
        var submittedAt: Date?
        var author: LoginPayload?
    }
    var createdAt: Date?
    var reviews: NodeList<Review>?
}

/// One of your reviews (`yours` in the documents).
struct YourReviewPayload: Decodable {
    var id: String?
    var state: String?              // APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED
    var submittedAt: Date?
}

/// A review's dismissal (`dismissals` in the documents): what it was before.
struct DismissalPayload: Decodable {
    struct Review: Decodable {
        var id: String?
    }
    var previousReviewState: String?    // APPROVED | CHANGES_REQUESTED
    var review: Review?
}

/// Someone else's PR you reviewed (done searches).
struct DoneReviewPayload: Decodable {
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var repo: RepoPayload?
    var yours: NodeList<YourReviewPayload>?
    var dismissals: NodeList<DismissalPayload>?
}

/// One of your PRs, merged (done searches).
struct DoneMergePayload: Decodable {
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var mergedAt: Date?
    var mergedBy: LoginPayload?
    var repo: RepoPayload?
}

/// A PR whose review request left the inbox (resolveDocument).
struct ResolvedPRPayload: Decodable {
    struct Request: Decodable {
        /// A user (`login`) or a team (`you`: its members matching your
        /// login — none when you're not on it); other kinds decode empty.
        struct Reviewer: Decodable {
            var login: String?
            var you: NodeList<LoginPayload>?
        }
        var requestedReviewer: Reviewer?
    }
    var id: String?
    var state: String?              // OPEN | CLOSED | MERGED
    var mergedAt: Date?
    var closedAt: Date?
    var mergedBy: LoginPayload?
    var pendingReviewers: NodeList<Request>?
    var yours: NodeList<YourReviewPayload>?
    var dismissals: NodeList<DismissalPayload>?
}
