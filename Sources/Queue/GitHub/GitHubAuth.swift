import Foundation

// OAuth device flow (spec "State Management" → Auth; onboarding surface 1e):
// startDeviceFlow() returns the code + URL the card displays, waitForSignIn()
// polls until the user authorizes on github.com, stores the token in the
// Keychain, and returns the login for `.signedIn(username:)`.
final class GitHubAuth: AuthProvider, @unchecked Sendable {
    private let settings: SettingsStore
    private let session: URLSession
    private let client: GitHubClient

    // Device-flow state between startDeviceFlow() and waitForSignIn().
    private var deviceCode: String?
    private var pollInterval: TimeInterval = 5
    private var expiresAt = Date.distantFuture

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
        self.client = GitHubClient(session: session)
    }

    /// UserDefaults "authMethod": how the user last signed in, "pat" or
    /// "device". Kept across sign-out so an expired session can reopen the
    /// right sign-in path.
    static let authMethodKey = "authMethod"

    /// Queue's own OAuth app (Device Flow enabled). A client ID is a public
    /// identifier, and the device flow — including token refresh — needs no
    /// client secret, so shipping it in the binary is safe.
    static let builtInClientID = "Ov23lictNX7V30UVHJAn"

    /// OAuth app client id for the device flow: the QUEUE_GITHUB_CLIENT_ID
    /// env var or the "githubClientID" user default override Queue's own app
    /// (for testing against a different OAuth app).
    static func clientID() throws -> String {
        if let id = ProcessInfo.processInfo.environment["QUEUE_GITHUB_CLIENT_ID"], !id.isEmpty {
            return id
        }
        if let id = UserDefaults.standard.string(forKey: "githubClientID"), !id.isEmpty {
            return id
        }
        return builtInClientID
    }

    /// Always true with the built-in client ID; stays a check so an empty
    /// override can't strand the sign-in card on the device flow.
    var supportsDeviceFlow: Bool { (try? Self.clientID()).map { !$0.isEmpty } ?? false }

    /// Clears the Keychain token and the cached login (AuthProvider.signOut,
    /// called from AppState.signOut()).
    func signOut() {
        Keychain.delete()
        Keychain.delete(account: Keychain.refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: "githubLogin")
    }

    // MARK: - AuthProvider

    /// Personal access token path: no OAuth app or client ID needed. The token
    /// is stored first (the client reads it from the Keychain), validated with
    /// GET /user, and removed again if GitHub rejects it. A PAT has no refresh
    /// token, so any stale one from a previous OAuth sign-in is cleared.
    func signIn(withToken token: String) async throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.api("Paste a token first.") }
        // Fine-grained tokens pass GET /user, then silently lose
        // notifications, check runs and every org but one.
        guard !trimmed.hasPrefix("github_pat_") else {
            throw GitHubError.api("Queue needs a classic token — fine-grained tokens can't read notifications or check runs and only cover one org.")
        }
        Keychain.delete(account: Keychain.refreshTokenAccount)
        guard Keychain.save(trimmed) else {
            throw GitHubError.api("Could not store the token in the Keychain.")
        }
        do {
            let login = try await fetchLogin()
            UserDefaults.standard.set(login, forKey: "githubLogin")
            UserDefaults.standard.set("pat", forKey: Self.authMethodKey)
            return login
        } catch {
            Keychain.delete()
            if let gitHubError = error as? GitHubError, gitHubError.isAuthError {
                throw GitHubError.api("GitHub rejected that token. Check it was copied in full and hasn't expired.")
            }
            throw error
        }
    }

    func startDeviceFlow() async throws -> DeviceFlowInfo {
        let clientID = try Self.clientID()
        let payload = try await postForm(
            URL(string: "https://github.com/login/device/code")!,
            // Classic-OAuth scopes: approve/merge need the full "repo" scope —
            // the spec's "repo:status + review write" has no classic-OAuth
            // equivalent (repo:status is read/write commit statuses only, and
            // there is no standalone review-write scope). read:org resolves
            // team names among your PRs' requested reviewers.
            params: ["client_id": clientID, "scope": "repo read:org"]
        )
        guard
            let device = payload["device_code"] as? String,
            let userCode = payload["user_code"] as? String,
            let verification = payload["verification_uri"] as? String,
            let verificationURL = URL(string: verification)
        else {
            throw GitHubError.api(oauthErrorMessage(payload) ?? "GitHub did not return a device code.")
        }
        deviceCode = device
        pollInterval = payload["interval"] as? TimeInterval ?? 5
        let expiresIn = payload["expires_in"] as? TimeInterval ?? 900
        expiresAt = Date().addingTimeInterval(expiresIn)
        return DeviceFlowInfo(userCode: userCode, verificationURL: verificationURL)
    }

    func waitForSignIn() async throws -> String {
        guard let deviceCode else {
            throw GitHubError.api("Device flow not started — call startDeviceFlow() first.")
        }
        let clientID = try Self.clientID()

        while true {
            if Date() >= expiresAt {
                throw GitHubError.api("The device code expired — start the sign-in again.")
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            let payload = try await postForm(
                URL(string: "https://github.com/login/oauth/access_token")!,
                params: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )

            if let token = payload["access_token"] as? String, !token.isEmpty {
                guard Keychain.save(token) else {
                    throw GitHubError.api("Could not store the token in the Keychain.")
                }
                // OAuth apps with token expiration also return a refresh token
                // (8h access tokens); TokenRefresher renews on 401.
                if let refresh = payload["refresh_token"] as? String, !refresh.isEmpty {
                    Keychain.save(refresh, account: Keychain.refreshTokenAccount)
                }
                let login: String
                do {
                    login = try await fetchLogin()
                } catch {
                    Keychain.delete()
                    Keychain.delete(account: Keychain.refreshTokenAccount)
                    throw error
                }
                UserDefaults.standard.set(login, forKey: "githubLogin")
                UserDefaults.standard.set("device", forKey: Self.authMethodKey)
                return login
            }

            switch payload["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                pollInterval += 5
            case "expired_token":
                throw GitHubError.api("The device code expired — start the sign-in again.")
            case "access_denied":
                throw GitHubError.api("Sign-in was denied on GitHub.")
            case let other?:
                throw GitHubError.api(oauthErrorMessage(payload) ?? "GitHub sign-in failed (\(other)).")
            case nil:
                throw GitHubError.api("Unexpected response while waiting for authorization.")
            }
        }
    }

    // MARK: - Internals

    /// GET /user with the stored token. A classic token without `repo`
    /// signs in fine but silently hides every private repo and can't approve
    /// or merge, so it's refused here (X-OAuth-Scopes lists what it has;
    /// fine-grained and app tokens send no such header).
    private func fetchLogin() async throws -> String {
        struct User: Decodable { var login: String }
        let (data, response) = try await client.restResponse(path: "user")
        if let header = response?.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            let scopes = GitHubClient.scopeList(header)
            guard scopes.contains("repo") else {
                Keychain.delete()
                throw GitHubError.api("That token is missing the repo scope, which Queue needs to see private repos and to approve and merge. Create a classic token with repo and read:org checked.")
            }
        }
        return try GitHubClient.decoder.decode(User.self, from: data).login
    }

    /// Form-encoded POST to a github.com OAuth endpoint (unauthenticated),
    /// Accept: application/json. Never logs parameters (they include codes).
    private func postForm(_ url: URL, params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // OAuth endpoints report flow errors (authorization_pending, …) in
            // the JSON body — some with non-2xx status. Fall through to parse
            // when the body is JSON; otherwise map to an HTTP error.
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                throw GitHubError.http(status: http.statusCode, message: "")
            }
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.api("Unexpected response from GitHub sign-in.")
        }
        return payload
    }

    private func oauthErrorMessage(_ payload: [String: Any]) -> String? {
        (payload["error_description"] as? String) ?? (payload["error"] as? String)
    }
}
