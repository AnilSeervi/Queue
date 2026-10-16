import Foundation

// Thin async URLSession client for api.github.com. Bearer token comes from the
// Keychain wrapper (memory-cached per process; never logged). A 401 triggers
// one refresh-token exchange + retry before surfacing as an auth error.

// MARK: - Errors

enum GitHubError: LocalizedError {
    /// No token in the Keychain (or the API rejected it → treat as signed out).
    case notSignedIn
    /// HTTP failure with GitHub's `message` payload when available.
    case http(status: Int, message: String)
    /// GraphQL / malformed-payload / OAuth errors.
    case api(String)
    /// rerunChecks on a PR with no failed Actions run.
    case noRunID

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to GitHub."
        case .http(let status, let message):
            return message.isEmpty ? "GitHub returned HTTP \(status)." : "\(message) (HTTP \(status))"
        case .api(let message):
            return message
        case .noRunID:
            return "No failed GitHub Actions run to re-run — other CI re-runs from its own page."
        }
    }

    /// GitHub's gateway gave up (its GraphQL timeout is ~10s).
    var isTimeout: Bool {
        if case .http(let status, _) = self { return status == 502 || status == 504 }
        return false
    }

    /// 401s (and a missing token) must abort the whole refresh; anything else
    /// fails only its own section.
    var isAuthError: Bool {
        switch self {
        case .notSignedIn: return true
        case .http(let status, _): return status == 401
        default: return false
        }
    }
}

/// One entry of a GraphQL response's `errors` array.
struct GraphQLError: Decodable, Hashable {
    enum PathElement: Decodable, Hashable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) {
                self = .index(index)
            } else {
                self = .key(try container.decode(String.self))
            }
        }
    }

    var message: String
    /// e.g. FORBIDDEN, NOT_FOUND, RATE_LIMITED.
    var type: String?
    var path: [PathElement]?

    /// Org SAML enforcement hid this part of the result.
    var isSAML: Bool {
        type == "FORBIDDEN" && message.localizedCaseInsensitiveContains("SAML")
    }
}

private struct GraphQLReply<D: Decodable>: Decodable {
    var data: D?
    var errors: [GraphQLError]?
}

/// SAML SSO state seen on responses since the last reset (X-GitHub-SSO or a
/// GraphQL SAML error). Lock-protected: a refresh's requests run concurrently.
final class SSOTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var notice: SSONotice?

    func reset() {
        lock.lock(); notice = nil; lock.unlock()
    }

    var current: SSONotice? {
        lock.lock(); defer { lock.unlock() }
        return notice
    }

    /// `.required` (a refused request, with its authorize URL) wins over
    /// `.partialResults`; partial org lists merge.
    func record(_ new: SSONotice) {
        lock.lock(); defer { lock.unlock() }
        switch (notice, new) {
        case (.required?, _):
            return
        case (.partialResults(let old)?, .partialResults(let more)):
            notice = .partialResults(orgs: old + more.filter { !old.contains($0) })
        default:
            notice = new
        }
    }

    /// `X-GitHub-SSO: required; url=https://github.com/orgs/…/sso?…` or
    /// `X-GitHub-SSO: partial-results; organizations=21955855,20582480`
    /// (organization ids, not logins).
    static func parse(_ header: String) -> SSONotice? {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let kind = parts.first else { return nil }
        func value(_ key: String) -> String? {
            parts.dropFirst()
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }
        switch kind {
        case "required":
            guard let raw = value("url"), let url = URL(string: raw) else { return nil }
            return .required(authorizeURL: url)
        case "partial-results":
            let orgs = (value("organizations") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .partialResults(orgs: orgs)
        default:
            return nil
        }
    }
}

// MARK: - Client

final class GitHubClient: @unchecked Sendable {
    static let apiBase = URL(string: "https://api.github.com")!

    private let session: URLSession
    /// SSO notices seen by this client; GitHubDataSource resets it per refresh.
    let sso = SSOTracker()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Shared decoder: GitHub's snake_case JSON + ISO-8601 dates
    /// (with or without fractional seconds). GraphQL's camelCase keys and
    /// Queue's aliases (which avoid underscores) pass through the snake_case
    /// conversion unchanged.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = plain.date(from: raw) ?? fractional.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: d.codingPath, debugDescription: "Unparseable date: \(raw)"))
        }
        return decoder
    }()

    private func bearerToken() throws -> String {
        guard let token = Keychain.load(), !token.isEmpty else { throw GitHubError.notSignedIn }
        return token
    }

    // MARK: REST

    /// Perform a REST call. `path` is relative to api.github.com ("repos/x/y/pulls/1")
    /// or a full https URL (notification comment URLs). Returns the raw body.
    @discardableResult
    func rest(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        try await restResponse(method: method, path: path, query: query, body: body).data
    }

    /// `rest` plus the HTTP response, for callers that read headers
    /// (X-OAuth-Scopes on the sign-in check).
    func restResponse(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        let base: URL
        if path.hasPrefix("http") {
            guard let url = URL(string: path) else { throw GitHubError.api("Bad URL: \(path)") }
            base = url
        } else {
            base = Self.apiBase.appendingPathComponent(path)
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GitHubError.api("Bad URL: \(path)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let url = components.url else { throw GitHubError.api("Bad URL: \(path)") }

        var retriedAuth = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Bearer \(try bearerToken())", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if let header = http?.value(forHTTPHeaderField: "X-GitHub-SSO"),
               let notice = SSOTracker.parse(header) {
                sso.record(notice)
            }
            do {
                try Self.check(response: response, data: data)
                return (data, http)
            } catch let error as GitHubError {
                // Expired access token (OAuth apps with token expiration issue
                // 8-hour tokens): exchange the refresh token and retry once.
                if case .http(let status, _) = error, status == 401, !retriedAuth {
                    retriedAuth = true
                    if await TokenRefresher.shared.refresh(session: session) { continue }
                }
                throw error
            }
        }
    }

    /// REST + decode into a model.
    func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await rest(method: method, path: path, query: query, body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: GraphQL

    /// Error-tolerant POST /graphql: decodes `data` alongside `errors` and
    /// throws only when `data` is null (rate limit, invalid document, …). A
    /// FORBIDDEN / SAML error on one alias comes back in `errors` with its
    /// path, so the caller can fail just that section.
    func graphql<T: Decodable>(
        _ type: T.Type,
        query: String,
        variables: [String: Any] = [:]
    ) async throws -> (data: T, errors: [GraphQLError]) {
        let (raw, response) = try await restResponse(
            method: "POST",
            path: "graphql",
            body: ["query": query, "variables": variables]
        )
        let reply: GraphQLReply<T>
        do {
            reply = try Self.decoder.decode(GraphQLReply<T>.self, from: raw)
        } catch {
            throw GitHubError.api("Malformed GraphQL response.")
        }
        let errors = reply.errors ?? []
        if errors.contains(where: \.isSAML) {
            // GraphQL names neither the org nor an authorize URL.
            sso.record(.partialResults(orgs: []))
        }
        guard let data = reply.data else {
            var message = errors.first?.message ?? "GitHub returned no data."
            // GraphQL's own rate limit answers 200 with RATE_LIMITED.
            if errors.contains(where: { $0.type == "RATE_LIMITED" }),
               let response, let hint = Self.rateLimitHint(response) {
                message += " — \(hint)"
            }
            throw GitHubError.api(message)
        }
        return (data, errors)
    }

    // MARK: Error mapping

    /// Map non-2xx responses to `GitHubError.http` carrying GitHub's `message`,
    /// plus what GitHub says the request needed (scopes / permissions) on 403
    /// and 404, and when a rate limit resets.
    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var message = ""
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = payload["message"] as? String {
            message = m
        }
        if message.isEmpty, http.statusCode == 502 || http.statusCode == 504 {
            message = "GitHub timed out"     // the body is an HTML error page
        }
        var hints: [String] = []
        if http.statusCode == 403 || http.statusCode == 404, let hint = accessHint(http) {
            hints.append(hint)
        }
        if http.statusCode == 403 || http.statusCode == 429, let hint = rateLimitHint(http) {
            hints.append(hint)
        }
        if !hints.isEmpty {
            message = ((message.isEmpty ? [] : [message]) + hints).joined(separator: " — ")
        }
        throw GitHubError.http(status: http.statusCode, message: message)
    }

    /// "token is missing the repo scope" when X-Accepted-OAuth-Scopes names
    /// scopes the token (X-OAuth-Scopes) lacks; fine-grained / app tokens get
    /// X-Accepted-GitHub-Permissions instead.
    private static func accessHint(_ http: HTTPURLResponse) -> String? {
        let accepted = scopeList(http.value(forHTTPHeaderField: "X-Accepted-OAuth-Scopes"))
        if !accepted.isEmpty, let grantedHeader = http.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            let granted = scopeList(grantedHeader)
            let covered = accepted.contains { want in granted.contains { scope($0, covers: want) } }
            if !covered {
                return "token is missing the \(accepted.joined(separator: " or ")) scope"
            }
        }
        if let permissions = http.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"),
           !permissions.trimmingCharacters(in: .whitespaces).isEmpty {
            return "needs token permission \(permissions)"
        }
        return nil
    }

    private static func rateLimitHint(_ http: HTTPURLResponse) -> String? {
        if let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
            return "retry in \(formatDuration(retry))"
        }
        guard http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
              let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
        else { return nil }
        return "rate limit resets in \(formatDuration(Date(timeIntervalSince1970: reset).timeIntervalSinceNow))"
    }

    static func scopeList(_ header: String?) -> [String] {
        (header ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Classic OAuth scope hierarchy: `repo` covers `repo:status`,
    /// `public_repo`, …; `admin:org` covers `write:org` and `read:org`.
    static func scope(_ granted: String, covers wanted: String) -> Bool {
        if granted == wanted || wanted.hasPrefix(granted + ":") { return true }
        if granted == "repo", ["public_repo", "repo_deployment", "security_events"].contains(wanted) { return true }
        let levels = ["read", "write", "admin"]
        let g = granted.split(separator: ":", maxSplits: 1).map(String.init)
        let w = wanted.split(separator: ":", maxSplits: 1).map(String.init)
        if g.count == 2, w.count == 2, g[1] == w[1],
           let gl = levels.firstIndex(of: g[0]), let wl = levels.firstIndex(of: w[0]) {
            return gl >= wl
        }
        return false
    }
}
