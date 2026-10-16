import Foundation

// What Queue itself saw you deal with, for the Done rows at the end of Inbox
// and My PRs. GitHub's searches cover the reviews you submitted and your
// merged PRs (Snapshot.doneReviews / mergedPRs); the log adds what only
// Queue sees: mentions you cleared, review requests that went away without
// your review, and approvals and merges made here before the search index
// has them.
//
// Storage: UserDefaults "doneLog", JSON. Items older than `doneWindow` are
// pruned. The log belongs to one login and goes on sign-out (not when the
// session expires: the same account usually signs back in).

/// A review request as last seen: enough to ask GitHub what became of it.
struct KnownRequest: Codable, Hashable {
    var id: String
    var repo: RepoRef
    var number: Int
    var title: String
    var url: URL
    var nodeID: String?
    var updatedAt: Date?
    /// The last refresh that listed it.
    var seenAt: Date
    /// Lookups that failed outright (gives up after `DoneLog.maxLookups`).
    var failedLookups = 0

    init(_ request: ReviewRequest, seenAt: Date) {
        id = request.id
        repo = request.repo
        number = request.number
        title = request.title
        url = request.url
        nodeID = request.nodeID
        updatedAt = request.updatedAt
        self.seenAt = seenAt
    }

    /// For resolveReviewRequests, which reads only these fields.
    var request: ReviewRequest {
        ReviewRequest(
            id: id, repo: repo, number: number, title: title,
            author: UserRef(login: ""), additions: 0, deletions: 0,
            age: Age(date: seenAt), url: url,
            nodeID: nodeID, updatedAt: updatedAt
        )
    }
}

struct DoneLog: Codable {
    /// The account it belongs to; "" = nobody yet.
    var login: String
    /// Inbox items and merges done here, one per id.
    var items: [DoneItem] = []
    /// Review requests the last good load listed. nil until the first load,
    /// which only sets this baseline: with nothing to compare against,
    /// nothing has gone away.
    var knownRequests: [KnownRequest]? = nil
    /// Requests that left the list, waiting for GitHub to say why.
    var vanished: [KnownRequest] = []

    static let defaultsKey = "doneLog"
    static let maxLookups = 3

    /// Adds `item`, or keeps the entry already there for its id when that
    /// one is preferred (DoneItem.preferred).
    mutating func record(_ item: DoneItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = DoneItem.preferred(items[index], item)
        } else {
            items.append(item)
        }
    }

    /// Drops items done before the window and requests last listed before
    /// it. Returns whether anything went.
    mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-doneWindow)
        let before = (items.count, vanished.count)
        items.removeAll { $0.doneAt < cutoff }
        vanished.removeAll { $0.seenAt < cutoff }
        return before != (items.count, vanished.count)
    }

    // MARK: Storage

    static func load() -> DoneLog? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(DoneLog.self, from: data)
    }

    /// Saves, or erases the stored log when it belongs to nobody.
    func save() {
        guard !login.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension DoneItem {
    /// Which of two entries for the same item to show: a review you
    /// submitted beats a request that went away without one, and a verdict
    /// beats a comment (a reply after approving here is still an approval;
    /// see GitHubDataSource.yourReview); otherwise the newer.
    static func preferred(_ a: DoneItem, _ b: DoneItem) -> DoneItem {
        if a.outcome.isReview != b.outcome.isReview { return a.outcome.isReview ? a : b }
        if a.outcome.isVerdict != b.outcome.isVerdict { return a.outcome.isVerdict ? a : b }
        return b.doneAt > a.doneAt ? b : a
    }

    /// One entry per id (`preferred`), done within `doneWindow`, newest first.
    static func combine(_ items: [DoneItem], now: Date) -> [DoneItem] {
        let cutoff = now.addingTimeInterval(-doneWindow)
        var byID: [String: DoneItem] = [:]
        for item in items where item.doneAt >= cutoff {
            byID[item.id] = byID[item.id].map { preferred($0, item) } ?? item
        }
        return byID.values.sorted { $0.doneAt == $1.doneAt ? $0.id < $1.id : $0.doneAt > $1.doneAt }
    }
}
