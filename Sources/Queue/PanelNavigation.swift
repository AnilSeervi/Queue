import AppKit

// Search, keyboard navigation and muting for the panel. The search filters
// the tab you're on (its open rows and its Done list): "#123" or "123"
// matches PR / issue numbers, anything else the title. The keyboard works
// on the rows in the order the tab shows them; letters always go to the
// search, so actions take modifiers: ↑/↓ move, ↩ opens, ⌘B copies the
// branch, ⌘O opens it in your editor, ⌘1–⌘4 switch tabs, ⌘F searches and
// Esc clears (the search, then the selection, then closes the panel).

/// What the panel's key monitor should do with a key press.
enum PanelKeyResult: Equatable {
    /// Handled here; drop the event.
    case consumed
    /// Not ours: let the window (and the search field) have it.
    case passThrough
    /// A printable key outside the search field: open the search with it.
    case typeIntoSearch(String)
}

/// A search query, parsed once.
struct SearchQuery: Equatable {
    let raw: String
    /// "#12" → 12 (numbers only); "12" → 12 (numbers or titles).
    let number: String?
    let numbersOnly: Bool
    let words: [String]

    init(_ raw: String) {
        self.raw = raw
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#"), text.dropFirst().allSatisfy(\.isNumber), text.count > 1 {
            number = String(text.dropFirst())
            numbersOnly = true
        } else if !text.isEmpty, text.allSatisfy(\.isNumber) {
            number = text
            numbersOnly = false
        } else {
            number = nil
            numbersOnly = false
        }
        words = text.split(separator: " ").map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    /// Number prefix (typing "48" finds #4821 on the way), or every word of
    /// the query in the title, ignoring case and accents.
    func matches(number: Int?, title: String) -> Bool {
        guard !isEmpty else { return true }
        if let wanted = self.number, let number, String(number).hasPrefix(wanted) { return true }
        if numbersOnly { return false }
        return words.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Rows flattened in the order a list tab shows them: by repo, stacks
/// together top layer first. The views group with the same functions.
func displayOrder<Item: Identifiable>(
    _ items: [Item], repo: (Item) -> RepoRef, stack: (Item) -> StackInfo?
) -> [Item] {
    groupByRepo(items, repo: repo).flatMap { group in
        stackSegments(group.items, stack: stack).flatMap { segment -> [Item] in
            switch segment {
            case .single(let item): return [item]
            case .stack(_, let layers): return layers
            }
        }
    }
}

extension InboxEntry {
    var number: Int? {
        switch self {
        case .review(let request): return request.number
        case .mention(let mention): return mention.number
        }
    }

    var title: String {
        switch self {
        case .review(let request): return request.title
        case .mention(let mention): return mention.title
        }
    }

    var stack: StackInfo? {
        if case .review(let request) = self { return request.stack }
        return nil
    }
}

extension AppState {
    // MARK: Search

    var query: SearchQuery { SearchQuery(searchText[activeTab] ?? "") }

    var isSearching: Bool { searchActive && !query.isEmpty }

    var searchedInbox: [InboxEntry] {
        let query = self.query
        return inbox.filter { query.matches(number: $0.number, title: $0.title) }
    }

    var searchedPRs: [MyPR] {
        let query = self.query
        return prs.filter { query.matches(number: $0.number, title: $0.title) }
    }

    var searchedIssues: [AssignedIssue] {
        let query = self.query
        return issues.filter { query.matches(number: $0.number, title: $0.title) }
    }

    func searched(_ done: [DoneItem]) -> [DoneItem] {
        let query = self.query
        return done.filter { query.matches(number: $0.number, title: $0.title) }
    }

    /// Opens the search on the current tab (⌘F, or typing in the panel).
    func showSearch(typing text: String = "") {
        guard activeTab != .stats else { return }
        if !text.isEmpty { searchText[activeTab, default: ""] += text }
        searchActive = true
        searchFocusToken += 1
    }

    func endSearch() {
        searchText[activeTab] = nil
        searchActive = false
        selectedRowID = nil
    }

    // MARK: Keyboard

    /// Row ids of the current tab in display order (searched).
    var navigableRowIDs: [String] {
        switch activeTab {
        case .inbox: return displayOrder(searchedInbox, repo: \.repo, stack: \.stack).map(\.id)
        case .prs: return displayOrder(searchedPRs, repo: \.repo, stack: \.stack).map(\.id)
        case .issues: return displayOrder(searchedIssues, repo: \.repo, stack: { _ in nil }).map(\.id)
        case .stats: return []
        }
    }

    func moveSelection(by step: Int) {
        let ids = navigableRowIDs
        guard !ids.isEmpty else { selectedRowID = nil; return }
        guard let current = selectedRowID, let index = ids.firstIndex(of: current) else {
            selectedRowID = step > 0 ? ids.first : ids.last
            return
        }
        selectedRowID = ids[max(0, min(ids.count - 1, index + step))]
    }

    /// The selection, or while searching the first match.
    private var targetRowID: String? {
        let ids = navigableRowIDs
        if let selected = selectedRowID, ids.contains(selected) { return selected }
        return isSearching ? ids.first : nil
    }

    @discardableResult
    func openSelected() -> Bool {
        guard let id = targetRowID else { return false }
        if let entry = inbox.first(where: { $0.id == id }) {
            open(entry.url)
            if case .mention(let mention) = entry { markRead(mention) }
        } else if let pr = prs.first(where: { $0.id == id }) {
            open(pr.url)
        } else if let issue = issues.first(where: { $0.id == id }) {
            open(issue.url)
        } else {
            return false
        }
        return true
    }

    private var selectedBranch: BranchRef? {
        guard let id = targetRowID else { return nil }
        if case .review(let request)? = inbox.first(where: { $0.id == id }) { return request.branchRef }
        return prs.first { $0.id == id }?.branchRef
    }

    @discardableResult
    func copySelectedBranch() -> Bool {
        guard let branch = selectedBranch?.branch else { return false }
        copyBranch(branch)
        return true
    }

    @discardableResult
    func openSelectedInEditor() -> Bool {
        guard let ref = selectedBranch else { return false }
        openInEditor(ref)
        return true
    }

    /// The panel's key presses. `fieldFocused`: the search field is being
    /// typed in, so plain keys and editing shortcuts are its own.
    func handlePanelKey(_ event: NSEvent, fieldFocused: Bool) -> PanelKeyResult {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 125: moveSelection(by: 1); return .consumed            // ↓
        case 126: moveSelection(by: -1); return .consumed           // ↑
        case 36, 76: return openSelected() ? .consumed : .passThrough  // ↩
        case 53:                                                       // Esc
            if searchActive {
                if query.isEmpty { endSearch() } else { searchText[activeTab] = nil; selectedRowID = nil }
                return .consumed
            }
            if selectedRowID != nil { selectedRowID = nil; return .consumed }
            return .passThrough
        default: break
        }
        if command, !flags.contains(.control), !flags.contains(.option) {
            switch key {
            case "f": showSearch(); return .consumed
            case "b": return copySelectedBranch() ? .consumed : .passThrough
            case "o": return openSelectedInEditor() ? .consumed : .passThrough
            case "1", "2", "3", "4":
                let tabs = PanelTab.allCases
                if let n = Int(key), n <= tabs.count { activeTab = tabs[n - 1]; selectedRowID = nil }
                return .consumed
            default: return .passThrough
            }
        }
        guard !fieldFocused, !flags.contains(.control), activeTab != .stats,
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return .passThrough }
        return .typeIntoSearch(text)
    }

    // MARK: Muting

    func isMuted(_ repo: RepoRef) -> Bool {
        settings.mutedRepos.contains { $0.caseInsensitiveCompare(repo.fullName) == .orderedSame }
    }

    /// Hides a repo from the lists, the badge, notifications and Up next.
    func mute(_ repo: RepoRef) {
        guard !isMuted(repo) else { return }
        settings.mutedRepos = (settings.mutedRepos + [repo.fullName]).sorted()
        inbox.removeAll { $0.repo.isSameRepo(as: repo) }
        prs.removeAll { $0.repo.isSameRepo(as: repo) }
        issues.removeAll { $0.repo.isSameRepo(as: repo) }
        if let selected = selectedRowID, !navigableRowIDs.contains(selected) { selectedRowID = nil }
        onStateChange?()
    }

    func unmute(_ fullName: String) {
        settings.mutedRepos.removeAll { $0.caseInsensitiveCompare(fullName) == .orderedSame }
        Task { await refresh() }
    }

    /// A refresh failed and nothing else is showing: offer Retry.
    var canRetryRefresh: Bool { refreshFailed && !isRefreshing }
}
