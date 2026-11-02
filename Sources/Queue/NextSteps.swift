import Foundation

// "Up next" in the footer: the most useful thing to do next, and the ones
// after it (› steps through them). Your PRs come first — feedback to
// address, threads to resolve, something to merge, CI to fix, conflicts,
// reviewers to nudge — then reviews (small ones first, as quick reviews)
// and mentions. Within a kind, whatever has waited longest leads.

struct NextStep: Identifiable, Hashable {
    enum Kind: Int, Comparable {
        case addressFeedback, resolveThreads, merge, fixCI, resolveConflicts, nudge, quickReview, review, reply

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var kind: Kind
    /// The row it's about (opening the step opens this).
    var itemID: String
    /// "Address feedback", "Merge 2 PRs", "Nudge @ana"…
    var action: String
    var title: String
    var age: Age
    var url: URL

    var id: String { "\(kind.rawValue)-\(itemID)" }
}

extension AppState {
    /// Lines changed for a review to count as quick.
    static let quickReviewLines = 150
    /// How long a PR waits on reviewers before Queue suggests a nudge.
    static let nudgeAfter: TimeInterval = 24 * 3600
    /// After a nudge, how long until Queue suggests (or offers) another.
    static let nudgeAgain: TimeInterval = 24 * 3600

    var nextSteps: [NextStep] {
        var steps: [NextStep] = []
        for pr in prs where !pr.isDraft {
            func add(_ kind: NextStep.Kind, _ action: String) {
                steps.append(NextStep(kind: kind, itemID: pr.id, action: action, title: pr.title, age: pr.age, url: pr.url))
            }
            if pr.changesRequested {
                add(.addressFeedback, "Address feedback")
            } else if pr.unresolvedThreads > 0 {
                add(.resolveThreads, "Resolve \(pr.unresolvedThreads) thread\(pr.unresolvedThreads == 1 ? "" : "s")")
            }
            if let layers = stackMerge(for: pr) {
                add(.merge, layers.count > 1 ? "Merge \(layers.count) PRs" : "Merge")
            }
            if pr.isFailing { add(.fixCI, "Fix CI") }
            if pr.hasConflicts { add(.resolveConflicts, "Resolve conflicts") }
            if canNudge(pr), Date().timeIntervalSince(pr.age.date) >= Self.nudgeAfter {
                add(.nudge, "Nudge " + nudgeNames(pr))
            }
        }
        for entry in inbox {
            switch entry {
            case .review(let request):
                let quick = request.additions + request.deletions <= Self.quickReviewLines
                steps.append(NextStep(
                    kind: quick ? .quickReview : .review, itemID: request.id,
                    action: quick ? "Quick review" : "Review", title: request.title, age: request.age, url: request.url
                ))
            case .mention(let mention) where mention.isDirect:
                steps.append(NextStep(
                    kind: .reply, itemID: mention.id, action: "Reply to \(mention.author?.login ?? "a mention")",
                    title: mention.comment, age: mention.age, url: mention.url
                ))
            case .mention:
                break
            }
        }
        // A PR shows up once, as its most pressing step.
        var seen: Set<String> = []
        return steps
            .sorted { ($0.kind, $0.age.date) < ($1.kind, $1.age.date) }
            .filter { seen.insert($0.itemID).inserted }
    }

    /// The step the footer shows (› moves on, wrapping around).
    var currentNextStep: NextStep? {
        let steps = nextSteps
        guard !steps.isEmpty else { return nil }
        return steps[upNextIndex % steps.count]
    }

    func showNextStep() {
        let count = nextSteps.count
        guard count > 1 else { return }
        upNextIndex = (upNextIndex + 1) % count
    }

    func openNextStep(_ step: NextStep) {
        open(step.url)
        if case .mention(let mention)? = inbox.first(where: { $0.id == step.itemID }) { markRead(mention) }
    }

    // MARK: Nudge

    /// Reviewers can be pinged: some haven't responded, the PR is up for
    /// review, and Queue didn't nudge on it in the last day.
    func canNudge(_ pr: MyPR) -> Bool {
        guard !pr.isDraft, !pr.reviewerMentions.isEmpty else { return false }
        if let last = nudgedAt[pr.id], Date().timeIntervalSince(last) < Self.nudgeAgain { return false }
        return true
    }

    func nudgeNames(_ pr: MyPR) -> String {
        let names = pr.reviewerMentions.map { "@" + ($0.split(separator: "/").last.map(String.init) ?? $0) }
        return names.count > 2 ? "\(names[0]) +\(names.count - 1)" : names.joined(separator: " ")
    }

    /// Posts the nudge comment; the row's icon asks for a second click first.
    func nudge(_ pr: MyPR) {
        guard canNudge(pr) else { return }
        clearActionError()
        let generation = sessionGeneration
        nudgedAt[pr.id] = Date()
        Task {
            do {
                try await dataSource.nudgeReviewers(pr)
                guard generation == sessionGeneration else { return }
                let message = "Nudged \(pr.reviewerMentions.map { "@\($0)" }.joined(separator: " ")) on #\(pr.number)"
                lastNudge = message
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if lastNudge == message { lastNudge = nil }
            } catch {
                guard generation == sessionGeneration else { return }
                nudgedAt[pr.id] = nil
                reportActionError("Nudge failed — \(error.localizedDescription)")
            }
        }
    }
}
