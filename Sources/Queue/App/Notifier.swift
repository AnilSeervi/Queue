import AppKit
import UserNotifications

/// macOS notifications for inbox events. After every refresh the app hands
/// over its lists and which sections failed; the notifier diffs them against
/// what it has already seen (persisted, so a relaunch doesn't re-announce old
/// items) and posts one notification per new event:
///
/// - a new review request, or a comment that @-mentions you
/// - CI turning red on one of your PRs
/// - changes requested on, or a merge conflict in, one of your PRs
/// - one of your PRs becoming ready to merge
///
/// The very first run (and the first after switching accounts) seeds
/// silently. A section that failed to load keeps what was seen before, so
/// the next good refresh doesn't announce it all again. PR transitions count
/// only while their state is known (CI or merge state `.unknown` keeps the
/// previous answer); changes requested and conflicts also skip a PR's first
/// sighting, while CI failing and ready announce a PR that shows up already
/// in that state. Mentions are tracked per mentioning comment, so a new
/// @-mention on a thread already listed still notifies. Three or more new items
/// of one kind in a single refresh collapse into one summary. Clicking a
/// notification opens the item on GitHub (a CI failure opens the failing
/// check; a summary opens the panel); a mention also marks its thread read.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// True when the user turned Queue's notifications off in System Settings.
    @Published private(set) var deniedInSystemSettings = false

    /// Opens the panel (summary notifications). Wired by AppDelegate.
    var openPanel: (() -> Void)?
    /// A mention notification was clicked: mark its thread read (thread id,
    /// the thread's updated_at when posted) and list it under Done (`done`,
    /// the row's entry as posted). Wired by AppDelegate.
    var onMentionOpened: ((_ threadID: String, _ threadUpdatedAt: Date?, _ done: DoneItem?) -> Void)?

    /// UNUserNotificationCenter crashes in an unbundled binary (`swift run`),
    /// so notifications only exist when running as Queue.app.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    private struct Seen: Codable {
        /// Account the sets belong to; another login starts over.
        var login: String?
        var reviews: Set<String> = []
        /// Direct mentions as `mentionKey`s (older releases stored bare row ids).
        var mentions: Set<String> = []
        /// Every open PR seen (changes requested and conflicts skip a PR's
        /// first sighting).
        var prs: Set<String> = []
        var failingPRs: Set<String> = []
        var readyPRs: Set<String> = []
        var changesPRs: Set<String> = []
        var conflictPRs: Set<String> = []

        init() {}

        // Fields added after the first release decode as empty, so an
        // upgrade keeps tracking instead of re-seeding.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            login = try c.decodeIfPresent(String.self, forKey: .login)
            reviews = try c.decodeIfPresent(Set<String>.self, forKey: .reviews) ?? []
            mentions = try c.decodeIfPresent(Set<String>.self, forKey: .mentions) ?? []
            prs = try c.decodeIfPresent(Set<String>.self, forKey: .prs) ?? []
            failingPRs = try c.decodeIfPresent(Set<String>.self, forKey: .failingPRs) ?? []
            readyPRs = try c.decodeIfPresent(Set<String>.self, forKey: .readyPRs) ?? []
            changesPRs = try c.decodeIfPresent(Set<String>.self, forKey: .changesPRs) ?? []
            conflictPRs = try c.decodeIfPresent(Set<String>.self, forKey: .conflictPRs) ?? []
        }
    }

    private static let seenKey = "notifierSeen"
    private var seen: Seen?
    private var requestedAuthorization = false

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.seenKey) {
            seen = try? JSONDecoder().decode(Seen.self, from: data)
        }
        center?.delegate = self
        refreshAuthorizationStatus()
    }

    // MARK: Diffing

    /// `inbox` / `prs` are what the app shows; `failed` names the sections
    /// whose data is stale this refresh.
    func process(
        inbox: [InboxEntry], prs: [MyPR], failed: Set<SnapshotSection>,
        login: String, settings: SettingsStore
    ) {
        if let seenLogin = seen?.login, seenLogin != login { reset() }
        let previous = seen
        // Seeding from a refresh that lost a section would leave that
        // section empty, and the next good refresh would announce all of it.
        if previous == nil, !failed.isDisjoint(with: [.reviews, .mentions, .prs]) { return }

        var current = Seen()
        current.login = login
        var reviews: [ReviewRequest] = []
        var mentions: [Mention] = []
        for entry in inbox {
            switch entry {
            case .review(let request): reviews.append(request)
            case .mention(let mention): mentions.append(mention)
            }
        }
        current.reviews = failed.contains(.reviews)
            ? previous?.reviews ?? [] : Set(reviews.map(\.id))
        if failed.contains(.mentions) {
            current.mentions = previous?.mentions ?? []
        } else {
            for mention in mentions {
                if mention.isDirect {
                    current.mentions.insert(Self.mentionKey(mention))
                } else if let previous {
                    // Activity row (or its comment couldn't be read): keep
                    // the thread's earlier mentions, so the same comment
                    // turning up again isn't announced twice.
                    let prefix = Self.mentionKey(threadOf: mention)
                    current.mentions.formUnion(previous.mentions.filter { $0.hasPrefix(prefix) })
                }
            }
        }

        var failing: [MyPR] = []
        var ready: [MyPR] = []
        var changes: [MyPR] = []
        var conflicts: [MyPR] = []
        if failed.contains(.prs), let previous {
            current.prs = previous.prs
            current.failingPRs = previous.failingPRs
            current.readyPRs = previous.readyPRs
            current.changesPRs = previous.changesPRs
            current.conflictPRs = previous.conflictPRs
        } else {
            current.prs = Set(prs.map(\.id))
            // Records `pr` in one set (`isMember` nil = unknown this refresh:
            // keep last refresh's answer). True when the PR newly entered the
            // set; a PR not seen last time counts only if `firstSighting`.
            // (Changes requested and conflicts are newer than the stored
            // sets, so an upgrade must not read every blocked PR as new.)
            func entered(
                _ set: WritableKeyPath<Seen, Set<String>>, _ pr: MyPR, _ isMember: Bool?,
                firstSighting: Bool = false
            ) -> Bool {
                let was = previous?[keyPath: set].contains(pr.id) ?? false
                if isMember ?? was { current[keyPath: set].insert(pr.id) }
                guard isMember == true, !was else { return false }
                return firstSighting || (previous?.prs.contains(pr.id) ?? false)
            }
            for pr in prs {
                let ciKnown = pr.ci != .unknown
                let mergeKnown = pr.mergeState != .unknown
                // A PR first seen already red (CI failed before the next
                // refresh) or ready still deserves the notification.
                if entered(\.failingPRs, pr, ciKnown ? pr.isFailing : nil, firstSighting: true) {
                    failing.append(pr)
                }
                let reviewsKnown = pr.reviewStateKnown
                // "Ready to merge" only when you can merge it yourself.
                if entered(\.readyPRs, pr, ciKnown && mergeKnown && reviewsKnown ? pr.isReady && pr.canWrite : nil,
                           firstSighting: true) {
                    ready.append(pr)
                }
                if entered(\.changesPRs, pr, reviewsKnown ? !pr.isDraft && pr.changesRequested : nil) {
                    changes.append(pr)
                }
                if entered(\.conflictPRs, pr, mergeKnown ? !pr.isDraft && pr.hasConflicts : nil) {
                    conflicts.append(pr)
                }
            }
        }

        // Tracking always tracks the current state, so an item that clears and
        // returns (CI green → red again) notifies again.
        persist(current)
        guard let previous else { return }   // first run: seed only

        var events: [Event] = []
        if settings.notifyReviewRequests, !failed.contains(.reviews) {
            events += batch(
                reviews.filter { !previous.reviews.contains($0.id) }.map(Event.review),
                summary: { "\($0) new review requests" }
            )
        }
        // Rows that are only new activity on an old mention thread stay quiet.
        // A bare row id is what an older release stored for an announced thread.
        if settings.notifyMentions, !failed.contains(.mentions) {
            events += batch(
                mentions.filter {
                    $0.isDirect && !previous.mentions.contains(Self.mentionKey($0))
                        && !previous.mentions.contains($0.id)
                }.map(Event.mention),
                summary: { "\($0) new mentions" }
            )
        }
        // One toggle covers everything that blocks your own PRs.
        if settings.notifyCIFailures {
            events += batch(failing.map(Event.ciFailed), summary: { "CI failed on \($0) of your PRs" })
            events += batch(changes.map(Event.changesRequested), summary: { "Changes requested on \($0) of your PRs" })
            events += batch(conflicts.map(Event.conflicts), summary: { "\($0) of your PRs have merge conflicts" })
        }
        if settings.notifyPRReady {
            events += batch(ready.map(Event.ready), summary: { "\($0) of your PRs are ready to merge" })
        }
        guard !events.isEmpty else { return }
        post(events)
    }

    /// Forget everything seen; the next refresh seeds silently.
    func reset() {
        seen = nil
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
    }

    /// "m-<thread>|<comment link>": a direct mention is seen per comment, so
    /// another @-mention on the same unread thread is new again.
    private static func mentionKey(_ mention: Mention) -> String {
        mentionKey(threadOf: mention) + mention.url.absoluteString
    }

    /// The prefix shared by every key of the mention's thread.
    private static func mentionKey(threadOf mention: Mention) -> String { "\(mention.id)|" }

    private enum Event {
        case review(ReviewRequest)
        case mention(Mention)
        case ciFailed(MyPR)
        case changesRequested(MyPR)
        case conflicts(MyPR)
        case ready(MyPR)
        case summary(title: String, body: String)
    }

    /// One or two new items → one notification each; three or more → a summary.
    private func batch(_ items: [Event], summary: (Int) -> String) -> [Event] {
        guard items.count >= 3 else { return items }
        let titles = items.prefix(3).map(Self.headline).joined(separator: " · ")
        return [.summary(title: summary(items.count), body: titles)]
    }

    private static func headline(_ event: Event) -> String {
        switch event {
        case .review(let r): return r.title
        case .mention(let m): return m.title
        case .ciFailed(let pr), .changesRequested(let pr), .conflicts(let pr), .ready(let pr):
            return pr.title
        case .summary(let title, _): return title
        }
    }

    // MARK: Posting

    private func post(_ events: [Event]) {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    events.forEach(self.deliver)
                case .notDetermined:
                    self.requestAuthorization { granted in
                        if granted { events.forEach(self.deliver) }
                    }
                default:
                    self.deniedInSystemSettings = true
                }
            }
        }
    }

    private func deliver(_ event: Event) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        var url: URL?
        var info: [String: Any] = [:]
        switch event {
        case .review(let r):
            content.title = "Review requested by \(r.author.login)"
            content.subtitle = "\(r.repo.fullName) #\(r.number)"
            content.body = r.title
            url = r.url
        case .mention(let m):
            content.title = "\(m.author?.login ?? "Someone") \(m.context)"
            content.subtitle = m.number.map { "\(m.repo.fullName) #\($0)" } ?? m.repo.fullName
            content.body = m.comment
            url = m.url
            if !m.threadID.isEmpty {
                info["threadID"] = m.threadID
                if let updated = m.threadUpdatedAt { info["threadUpdatedAt"] = updated.timeIntervalSince1970 }
                // The row may be gone by the time this is clicked.
                info["done"] = try? JSONEncoder().encode(DoneItem.cleared(m))
            }
        case .ciFailed(let pr):
            content.title = "CI failed: \(pr.pillText)"
            content.subtitle = "\(pr.repo.fullName) #\(pr.number)"
            content.body = pr.title
            // Same target as the row's ✕: the first failing check's log.
            url = pr.failingCheckURL ?? pr.url
        case .changesRequested(let pr):
            content.title = "Changes requested"
            content.subtitle = "\(pr.repo.fullName) #\(pr.number)"
            content.body = pr.title
            url = pr.url
        case .conflicts(let pr):
            content.title = "Merge conflicts"
            content.subtitle = "\(pr.repo.fullName) #\(pr.number)"
            content.body = pr.title
            url = pr.url
        case .ready(let pr):
            content.title = "Ready to merge"
            content.subtitle = "\(pr.repo.fullName) #\(pr.number)"
            content.body = pr.title
            url = pr.url
        case .summary(let title, let body):
            content.title = title
            content.body = body
        }
        if let url { info["url"] = url.absoluteString }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center?.add(request)
    }

    // MARK: Authorization

    /// Ask once, the first time there's something to say.
    private func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let center, !requestedAuthorization else { return }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.deniedInSystemSettings = !granted
                completion(granted)
            }
        }
    }

    /// Ask at launch (once), so the system prompt shows up front instead of
    /// on the first event.
    func requestPermissionIfNeeded() {
        center?.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in self?.requestAuthorization { _ in } }
        }
    }

    /// Re-read the system setting (Settings window shows a warning when off).
    func refreshAuthorizationStatus() {
        center?.getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self?.deniedInSystemSettings = denied }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func persist(_ value: Seen) {
        seen = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.seenKey)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Menu bar apps are always "foreground"; show the banner anyway.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let link = info["url"] as? String
        let threadID = info["threadID"] as? String
        let threadUpdatedAt = (info["threadUpdatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        let done = (info["done"] as? Data).flatMap { try? JSONDecoder().decode(DoneItem.self, from: $0) }
        Task { @MainActor in
            if let threadID {
                Notifier.shared.onMentionOpened?(threadID, threadUpdatedAt, done)
            }
            if let link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                Notifier.shared.openPanel?()
            }
            completionHandler()
        }
    }
}
