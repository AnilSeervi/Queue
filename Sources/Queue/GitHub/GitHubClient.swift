import Foundation

// Thin async URLSession client for api.github.com. Bearer token comes from the
// Keychain wrapper (memory-cached per process; never logged). A 401 triggers
// one refresh-token exchange + retry before surfacing as an auth error.

// MARK: - Errors

enum GitHubError: LocalizedError {
    /// No token in the Keychain (or the API rejected it → treat as signed out).
    case notSignedIn
    case missingClientID
    /// HTTP failure with GitHub's `message` payload when available.
    case http(status: Int, message: String)
    /// GraphQL / malformed-payload / OAuth errors.
    case api(String)
    /// rerunChecks with no remembered Actions run id.
    case noRunID

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to GitHub."
        case .missingClientID:
            return "Set a GitHub OAuth app client ID via the QUEUE_GITHUB_CLIENT_ID environment variable or the \"githubClientID\" user default, then try again."
        case .http(let status, let message):
            return message.isEmpty ? "GitHub returned HTTP \(status)." : "\(message) (HTTP \(status))"
        case .api(let message):
            return message
        case .noRunID:
            return "No recent Actions run is known for this PR — refresh and try again."
        }
    }

    /// 401s (and a missing token) must abort the whole refresh; anything else
    /// degrades to an empty section.
    var isAuthError: Bool {
        switch self {
        case .notSignedIn: return true
        case .http(let status, _): return status == 401
        default: return false
        }
    }
}

// MARK: - Client

final class GitHubClient: @unchecked Sendable {
    static let apiBase = URL(string: "https://api.github.com")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Shared decoder: GitHub's snake_case JSON + ISO-8601 dates
    /// (with or without fractional seconds).
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
            do {
                try Self.check(response: response, data: data)
                return data
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

    /// POST /graphql; returns the `data` object as loose JSON. GraphQL-level
    /// errors are surfaced as `GitHubError.api` with GitHub's message.
    func graphql(query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try await rest(
            method: "POST",
            path: "graphql",
            body: ["query": query, "variables": variables]
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.api("Malformed GraphQL response.")
        }
        if let errors = object["errors"] as? [[String: Any]],
           let message = errors.compactMap({ $0["message"] as? String }).first {
            throw GitHubError.api(message)
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    // MARK: Error mapping

    /// Map non-2xx responses to `GitHubError.http` carrying GitHub's `message`.
    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var message = ""
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = payload["message"] as? String {
            message = m
        }
        throw GitHubError.http(status: http.statusCode, message: message)
    }
}
