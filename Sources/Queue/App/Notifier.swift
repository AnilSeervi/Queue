import AppKit
import UserNotifications

/// macOS notifications for inbox events. After every successful refresh the
/// app hands over the fresh lists; the notifier diffs them against what it has
/// already seen (persisted, so a relaunch doesn't re-announce old items) and
/// posts one notification per new event:
///
/// - a new review request or mention
/// - CI turning red on one of your PRs
/// - one of your PRs becoming ready to merge
///
/// The very first run seeds silently. Three or more new items of one kind in a
/// single refresh collapse into one summary. Snooze-all (DND) keeps tracking
/// but posts nothing. Clicking a notification opens the item on GitHub (or the
/// panel, for a summary).
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// True when the user turned Queue's notifications off in System Settings.
    @Published private(set) var deniedInSystemSettings = false

    /// Opens the panel (summary notifications). Wired by AppDelegate.
    var openPanel: (() -> Void)?

    /// UNUserNotificationCenter crashes in an unbundled binary (`swift run`),
    /// so notifications only exist when running as Queue.app.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    private struct Seen: Codable {
        var reviews: Set<String> = []
        var mentions: Set<String> = []
        var failingPRs: Set<String> = []
        var readyPRs: Set<String> = []
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

    func process(inbox: [InboxEntry], prs: [MyPR], settings: SettingsStore, quiet: Bool) {
        var current = Seen()
        var reviews: [ReviewRequest] = []
        var mentions: [Mention] = []
        for entry in inbox {
            switch entry {
            case .review(let request):
                current.reviews.insert(request.id)
                reviews.append(request)
            case .mention(let mention):
                current.mentions.insert(mention.id)
                mentions.append(mention)
            }
        }
        let failing = prs.filter(\.isFailing)
        let ready = prs.filter(\.isReady)
        current.failingPRs = Set(failing.map(\.id))
        current.readyPRs = Set(ready.map(\.id))

        let previous = seen
        // Tracking always tracks the current state, so an item that clears and
        // returns (CI green → red again) notifies again.
        persist(current)
        guard let previous, !quiet else { return }   // first run: seed only

        var events: [Event] = []
        if settings.notifyReviewRequests {
            events += batch(
                reviews.filter { !previous.reviews.contains($0.id) }.map(Event.review),
                summary: { "\($0) new review requests" }
            )
        }
        if settings.notifyMentions {
            events += batch(
                mentions.filter { !previous.mentions.contains($0.id) }.map(Event.mention),
                summary: { "\($0) new mentions" }
            )
        }
        if settings.notifyCIFailures {
            events += batch(
                failing.filter { !previous.failingPRs.contains($0.id) }.map(Event.ciFailed),
                summary: { "CI failed on \($0) of your PRs" }
            )
        }
        if settings.notifyPRReady {
            events += batch(
                ready.filter { !previous.readyPRs.contains($0.id) }.map(Event.ready),
                summary: { "\($0) of your PRs are ready to merge" }
            )
        }
        guard !events.isEmpty else { return }
        post(events)
    }

    private enum Event {
        case review(ReviewRequest)
        case mention(Mention)
        case ciFailed(MyPR)
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
        case .ciFailed(let pr), .ready(let pr): return pr.title
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
        switch event {
        case .review(let r):
            content.title = "Review requested by \(r.author.login)"
            content.subtitle = "\(r.repo.fullName) #\(r.number)"
            content.body = r.title
            url = r.url
        case .mention(let m):
            content.title = "\(m.author.login) \(m.context)"
            content.subtitle = "\(m.repo.fullName) #\(m.number)"
            content.body = m.comment
            url = m.url
        case .ciFailed(let pr):
            content.title = "CI failed: \(pr.pillText)"
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
        if let url { content.userInfo = ["url": url.absoluteString] }
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
        let link = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            if let link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                Notifier.shared.openPanel?()
            }
            completionHandler()
        }
    }
}
