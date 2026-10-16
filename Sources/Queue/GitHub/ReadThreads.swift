import Foundation

// Mention threads the user has dealt with (opened the row, or ✓ Done).
//
// Marking a thread read on GitHub isn't enough to drop the row: the PATCH
// can fail, and /notifications can go on listing the thread for a while
// afterwards. So Queue keeps its own note per thread — the thread's
// `updated_at` at the moment it was dealt with — and hides the thread while
// GitHub reports that same moment (or an older one). Any newer activity, such
// as another comment, moves `updated_at` on and the row comes back.
//
// Storage: UserDefaults "readThreads", a property-list dictionary
// [threadID: Date]. Values written as ISO-8601 strings or epoch seconds are
// read too, so every writer's notes count.
enum ReadThreads {
    static let defaultsKey = "readThreads"
    /// A note outlives its thread in the feed by this long, then goes.
    static let retention: TimeInterval = 30 * 86400

    /// Refresh prunes from a background task while the main actor marks;
    /// every read-modify-write of the dictionary holds this.
    private static let lock = NSLock()

    /// threadID → the thread's updated_at when it was dealt with.
    static func markers() -> [String: Date] {
        stored().compactMapValues(readDate)
    }

    /// Notes `threadID` as dealt with as of `updatedAt` (now when unknown).
    static func mark(_ threadID: String, updatedAt: Date?) {
        guard !threadID.isEmpty else { return }
        edit { notes in
            notes[threadID] = updatedAt ?? Date()
            return true
        }
    }

    /// Hidden: noted, and nothing has happened on the thread since.
    static func isRead(threadID: String, updatedAt: Date?, markers: [String: Date]) -> Bool {
        guard let notedAt = markers[threadID] else { return false }
        return updatedAt.map { $0 <= notedAt } ?? true
    }

    /// Forgets notes on threads the feed no longer returns once they're
    /// older than `retention` (unreadable ones at once). Kept notes stay in
    /// whatever form their writer stored.
    static func prune(fetched threadIDs: Set<String>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retention)
        edit { notes in
            let expired = notes.filter { id, value in
                !threadIDs.contains(id) && (readDate(value).map { $0 < cutoff } ?? true)
            }
            expired.keys.forEach { notes.removeValue(forKey: $0) }
            return !expired.isEmpty
        }
    }

    // MARK: Storage

    private static func stored() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
    }

    /// Locked read-modify-write; `change` returns whether to save.
    private static func edit(_ change: (inout [String: Any]) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        var notes = stored()
        if change(&notes) { UserDefaults.standard.set(notes, forKey: defaultsKey) }
    }

    private static func readDate(_ value: Any) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}
