import Foundation
import Security

// Minimal generic-password Keychain wrapper for the GitHub OAuth token
// (spec "State Management": "token in Keychain"; onboarding footnote
// "Token stays in your Keychain"). No external dependencies.
//
// The loaded value is cached in memory for the life of the process: the
// Keychain is hit once per launch, not once per API request — otherwise a
// dev build (ad-hoc signed, so the ACL can't durably trust it) triggers an
// access prompt for every network call.
enum Keychain {
    static let service = "com.queueapp.Queue"
    static let tokenAccount = "github-token"
    static let refreshTokenAccount = "github-refresh-token"

    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    /// Save (or overwrite) a string secret. Returns true on success.
    @discardableResult
    static func save(_ value: String, account: String = tokenAccount) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place if an item already exists; add otherwise.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        let ok = status == errSecSuccess
        if ok {
            lock.lock()
            cache[account] = value
            lock.unlock()
        }
        return ok
    }

    /// Load a string secret; nil when absent (or unreadable). Cached per
    /// process after the first read.
    static func load(account: String = tokenAccount) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String?
        if status == errSecSuccess, let data = result as? Data {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        // Cache the miss too — an absent token shouldn't re-prompt every call.
        // save() repopulates after sign-in.
        lock.lock()
        cache[account] = value
        lock.unlock()
        return value
    }

    /// Delete a stored secret (no-op when absent).
    static func delete(account: String = tokenAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock()
        cache[account] = String?.none
        lock.unlock()
    }
}
