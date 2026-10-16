import Foundation

// Recognizing a GitHub repo in a git remote URL, in whichever form a clone
// uses it:
//
//   https://github.com/owner/repo(.git)    git@github.com:owner/repo(.git)
//   ssh://git@github.com(:22)/owner/repo    git://github.com/owner/repo
//
// with or without a user name or trailing slash, plus SSH host aliases from
// multi-account setups (git@github.com-work:owner/repo). Owners and repo
// names compare case-insensitively, as on GitHub. `url.<base>.insteadOf`
// rules from your git config apply the way git applies them, so shorthand
// remotes ("gh:owner/repo") match too.

enum RemoteTransport: String, Codable, Hashable, Sendable {
    case ssh, https, other
}

/// The GitHub repo a remote URL points to.
struct GitHubRemoteURL: Hashable, Sendable {
    var repo: RepoRef
    var transport: RemoteTransport

    init?(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: Substring
        if let separator = url.range(of: "://") {
            let scheme = url[..<separator.lowerBound].lowercased()
            let rest = url[separator.upperBound...]
            let authority = rest.prefix { $0 != "/" }
            path = rest.dropFirst(authority.count)
            // Drop "user[:password]@" and ":port".
            let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            host = String(hostAndPort.prefix { $0 != ":" }).lowercased()
            switch scheme {
            case "ssh", "git+ssh", "ssh+git": transport = .ssh
            case "https", "http": transport = .https
            default: transport = .other
            }
        } else {
            // scp-like "[user@]host:path": a colon before any slash.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            let authority = url[..<colon]
            host = String(authority.split(separator: "@", omittingEmptySubsequences: false).last ?? "").lowercased()
            path = url[url.index(after: colon)...]
            transport = .ssh
        }
        guard Self.isGitHub(host: host, transport: transport) else { return nil }

        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        repo = RepoRef(owner: String(parts[0]), name: name)
    }

    /// github.com (and its www / ssh.github.com:443 names), or an SSH alias
    /// named after it ("github.com-work", "github-personal").
    private static func isGitHub(host: String, transport: RemoteTransport) -> Bool {
        if ["github.com", "www.github.com", "ssh.github.com"].contains(host) { return true }
        return transport == .ssh && (host.hasPrefix("github.com-") || host.hasPrefix("github-"))
    }
}

extension RepoRef {
    /// The same repo on GitHub, where names are case-insensitive.
    func isSameRepo(as other: RepoRef) -> Bool {
        owner.caseInsensitiveCompare(other.owner) == .orderedSame
            && name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    /// Key for caches: "owner/repo", lowercased.
    var cacheKey: String { fullName.lowercased() }
}

// MARK: - insteadOf

/// `url.<base>.insteadOf <prefix>` rules from git config: the longest
/// matching prefix is replaced by its base, as git does.
struct URLRewrites: Sendable {
    var rules: [(prefix: String, base: String)] = []

    func apply(_ url: String) -> String {
        guard let rule = rules.filter({ url.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count })
        else { return url }
        return rule.base + url.dropFirst(rule.prefix.count)
    }

    /// Your global and system rules (and `folder`'s own, if it's a repo).
    static func load(using git: GitRunner, in folder: URL) async -> URLRewrites {
        guard let output = try? await git.run(["config", "-z", "--get-regexp", #"^url\..*\.insteadof$"#], in: folder),
              output.succeeded
        else { return URLRewrites() }
        // -z: "key\nvalue\0" per entry; key is "url.<base>.insteadof".
        let rules = output.stdout.split(separator: "\0").compactMap { entry -> (prefix: String, base: String)? in
            let lines = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2 else { return nil }
            let key = lines[0], suffix = ".insteadof"
            guard key.hasPrefix("url."), key.lowercased().hasSuffix(suffix) else { return nil }
            let base = key.dropFirst(4).dropLast(suffix.count)
            return lines[1].isEmpty ? nil : (prefix: String(lines[1]), base: String(base))
        }
        return URLRewrites(rules: rules)
    }
}

// MARK: - .git/config

/// Remote URLs read straight from a repo's .git/config: the clone scan looks
/// at many repos, and starting git for each would be slow. Covers what git
/// writes there ([remote "name"] sections, quoting, comments); not includes.
enum GitConfigFile {
    static func remotes(at configURL: URL) -> [(name: String, url: String)] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        var remotes: [(name: String, url: String)] = []
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)[...]
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { continue }
                section = remoteName(inHeader: line[line.index(after: line.startIndex)..<close])
                line = line[line.index(after: close)...].drop { $0 == " " || $0 == "\t" }
                if line.isEmpty { continue }
            }
            guard let name = section, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "url" {
                let value = parseValue(line[line.index(after: equals)...])
                if !value.isEmpty { remotes.append((name: name, url: value)) }
            }
        }
        return remotes
    }

    /// `remote "origin"` → "origin" (also the old `remote.origin` form); nil
    /// for other sections.
    private static func remoteName(inHeader header: Substring) -> String? {
        let header = header.trimmingCharacters(in: .whitespaces)
        if let quote = header.firstIndex(of: "\"") {
            guard header[..<quote].trimmingCharacters(in: .whitespaces).lowercased() == "remote" else { return nil }
            var name = ""
            var escaped = false
            for character in header[header.index(after: quote)...] {
                if escaped { name.append(character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { break }
                else { name.append(character) }
            }
            return name
        }
        let parts = header.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "remote" else { return nil }
        return String(parts[1])
    }

    /// A value with git's quoting, escapes and trailing comments handled.
    private static func parseValue(_ raw: Substring) -> String {
        var value = ""
        var quoted = false
        var escaped = false
        for character in raw {
            if escaped {
                switch character {
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "#" || character == ";" {
                break
            } else {
                value.append(character)
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
