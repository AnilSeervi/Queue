import Foundation

/// OAuth apps created with "Expire user authorization tokens" enabled issue
/// 8-hour access tokens plus a refresh token. When the API answers 401, the
/// client asks this actor to exchange the stored refresh token for a fresh
/// pair and retries once. Single-flight: concurrent 401s (a refresh fans out
/// many requests) share one exchange.
actor TokenRefresher {
    static let shared = TokenRefresher()

    private var inFlight: Task<Bool, Never>?

    /// Returns true when a new access token was stored.
    func refresh(session: URLSession) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await Self.perform(session: session) }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        return ok
    }

    private static func perform(session: URLSession) async -> Bool {
        guard
            let refreshToken = Keychain.load(account: Keychain.refreshTokenAccount),
            !refreshToken.isEmpty,
            let clientID = try? GitHubAuth.clientID()
        else { return false }

        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        guard
            let (data, _) = try? await session.data(for: request),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = payload["access_token"] as? String, !token.isEmpty
        else { return false }

        Keychain.save(token)
        // GitHub rotates the refresh token on every use.
        if let rotated = payload["refresh_token"] as? String, !rotated.isEmpty {
            Keychain.save(rotated, account: Keychain.refreshTokenAccount)
        }
        return true
    }
}
