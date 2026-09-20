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

    /// OAuth app client id: QUEUE_GITHUB_CLIENT_ID env var, or the
    /// "githubClientID" user default. Required for the device flow.
    static func clientID() throws -> String {
        if let id = ProcessInfo.processInfo.environment["QUEUE_GITHUB_CLIENT_ID"], !id.isEmpty {
            return id
        }
        if let id = UserDefaults.standard.string(forKey: "githubClientID"), !id.isEmpty {
            return id
        }
        throw GitHubError.missingClientID
    }

    /// Clears the Keychain token and the cached login (AuthProvider.signOut,
    /// called from AppState.signOut()).
    func signOut() {
        Keychain.delete()
        Keychain.delete(account: Keychain.refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: "githubLogin")
    }

    // MARK: - AuthProvider

    func startDeviceFlow() async throws -> DeviceFlowInfo {
        let clientID = try Self.clientID()
        let payload = try await postForm(
            URL(string: "https://github.com/login/device/code")!,
            // Classic-OAuth scopes: approve/merge need the full "repo" scope —
            // the spec's "repo:status + review write" has no classic-OAuth
            // equivalent (repo:status is read/write commit statuses only, and
            // there is no standalone review-write scope). read:org lists the
            // org's repos for onboarding/settings.
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
                let login = try await fetchLogin()
                UserDefaults.standard.set(login, forKey: "githubLogin")
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

    /// Repos available to watch, with open-PR counts (onboarding step 2 and
    /// Settings). Empty organization = the signed-in user's own repositories.
    /// One GraphQL query; REST fallback when GraphQL is unavailable.
    func fetchWatchableRepos() async throws -> [WatchableRepo] {
        let org = await MainActor.run { settings.organization }
            .trimmingCharacters(in: .whitespaces)
        do {
            return org.isEmpty
                ? try await fetchViewerReposGraphQL()
                : try await fetchWatchableReposGraphQL(org: org)
        } catch let error as GitHubError where error.isAuthError {
            throw error
        } catch {
            return try await fetchWatchableReposREST(org: org)
        }
    }

    // MARK: - Internals

    private func fetchLogin() async throws -> String {
        struct User: Decodable { var login: String }
        let user: User = try await client.get("user")
        return user.login
    }

    private func fetchWatchableReposGraphQL(org: String) async throws -> [WatchableRepo] {
        let query = """
        query($org: String!) {
          organization(login: $org) {
            repositories(first: 20, orderBy: {field: PUSHED_AT, direction: DESC}) {
              nodes {
                name
                owner { login }
                pullRequests(states: OPEN) { totalCount }
              }
            }
          }
        }
        """
        let data = try await client.graphql(query: query, variables: ["org": org])
        guard
            let organization = data["organization"] as? [String: Any],
            let repositories = organization["repositories"] as? [String: Any],
            let nodes = repositories["nodes"] as? [[String: Any]]
        else {
            throw GitHubError.api("Organization \"\(org)\" not found or not accessible.")
        }
        return Self.mapRepoNodes(nodes)
    }

    /// The signed-in user's own repos (owner / collaborator / org member).
    private func fetchViewerReposGraphQL() async throws -> [WatchableRepo] {
        let query = """
        query {
          viewer {
            repositories(
              first: 20,
              orderBy: {field: PUSHED_AT, direction: DESC},
              affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]
            ) {
              nodes {
                name
                owner { login }
                pullRequests(states: OPEN) { totalCount }
              }
            }
          }
        }
        """
        let data = try await client.graphql(query: query, variables: [:])
        guard
            let viewer = data["viewer"] as? [String: Any],
            let repositories = viewer["repositories"] as? [String: Any],
            let nodes = repositories["nodes"] as? [[String: Any]]
        else {
            throw GitHubError.api("Could not list your repositories.")
        }
        return Self.mapRepoNodes(nodes)
    }

    private static func mapRepoNodes(_ nodes: [[String: Any]]) -> [WatchableRepo] {
        nodes.compactMap { node in
            guard
                let name = node["name"] as? String,
                let owner = (node["owner"] as? [String: Any])?["login"] as? String
            else { return nil }
            let open = ((node["pullRequests"] as? [String: Any])?["totalCount"] as? Int) ?? 0
            return WatchableRepo(repo: RepoRef(owner: owner, name: name), openPRs: open)
        }
    }

    private func fetchWatchableReposREST(org: String) async throws -> [WatchableRepo] {
        struct Repo: Decodable {
            struct Owner: Decodable { var login: String }
            var name: String
            var owner: Owner
        }
        // Empty org → the user's own repos.
        let path = org.isEmpty ? "user/repos" : "orgs/\(org)/repos"
        var queryItems = [URLQueryItem(name: "sort", value: "pushed"),
                          URLQueryItem(name: "per_page", value: "20")]
        if org.isEmpty {
            queryItems.append(URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"))
        }
        let repos: [Repo] = try await client.get(path, query: queryItems)
        struct SearchCount: Decodable { var totalCount: Int }
        // Open-PR counts via search, best-effort (0 on failure).
        return await withTaskGroup(of: (Int, WatchableRepo).self) { group in
            for (index, repo) in repos.enumerated() {
                group.addTask { [client] in
                    let ref = RepoRef(owner: repo.owner.login, name: repo.name)
                    let count: Int
                    do {
                        let result: SearchCount = try await client.get(
                            "search/issues",
                            query: [URLQueryItem(name: "q", value: "is:open is:pr repo:\(ref.fullName)"),
                                    URLQueryItem(name: "per_page", value: "1")]
                        )
                        count = result.totalCount
                    } catch {
                        count = 0
                    }
                    return (index, WatchableRepo(repo: ref, openPRs: count))
                }
            }
            var ordered: [(Int, WatchableRepo)] = []
            for await entry in group { ordered.append(entry) }
            return ordered.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
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
