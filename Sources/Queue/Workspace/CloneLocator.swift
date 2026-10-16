import Foundation

// Finding your clone of a repo in your code folder (Settings → Code folder,
// e.g. ~/Projects), or cloning it there when you have none.
//
// The scan goes up to three folders deep, breadth-first, and never inside a
// repo. It skips symlinks, app bundles, node_modules, Library and
// "*.worktrees" folders, and hidden folders unless they're repos themselves
// (".github" is a common one). A repo is your clone of owner/repo when any
// of its remotes points there (GitHubRemoteURL). What a scan finds is cached
// (UserDefaults "cloneCache") and checked again before each use.
//
// A missing clone is cloned into <code folder>/<repo> (<owner>-<repo> when
// that's taken) over the protocol your other clones use — SSH if they use
// git@github.com, else HTTPS — with your own git credentials.

struct GitRemote: Hashable, Sendable {
    var name: String
    /// As configured.
    var url: String
    /// Where it points on GitHub (through insteadOf when the URL itself isn't
    /// GitHub's); nil for other hosts and local paths.
    var github: GitHubRemoteURL?
}

/// A main working tree (never a linked worktree) and its remotes.
struct GitClone: Hashable, Sendable {
    /// Canonical path of the working tree.
    var path: String
    var remotes: [GitRemote]

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// "<clone>.worktrees", beside the clone: where Queue adds worktrees.
    var worktreesFolder: String { path + ".worktrees" }

    /// The remote for `repo`: origin first, then upstream, then by name.
    func remote(for repo: RepoRef) -> GitRemote? {
        func rank(_ remote: GitRemote) -> (Int, String) {
            (remote.name == "origin" ? 0 : remote.name == "upstream" ? 1 : 2, remote.name)
        }
        return remotes
            .filter { $0.github?.repo.isSameRepo(as: repo) == true }
            .min { rank($0) < rank($1) }
    }
}

struct CloneLocator: Sendable {
    static let maxDepth = 3
    /// Folders looked at per scan, at most (a code folder of ~/ stays quick).
    static let maxFolders = 5000
    static let skippedFolders: Set<String> = ["node_modules", "Library", "DerivedData", "Pods", "bower_components"]
    static let cacheKey = "cloneCache"

    struct Cache: Codable {
        /// RepoRef.cacheKey → clone path.
        var paths: [String: String] = [:]
        /// The last scan's GitHub remotes were mostly SSH ones; nil = it found none.
        var prefersSSH: Bool?
    }

    var git: GitRunner
    var storage: WorkspaceStorage

    /// The clone of the first of `repos` you have in `codeFolder` (a
    /// canonical path): the cached one while it still checks out, else the
    /// best a scan finds — one whose origin points there, then the shallowest.
    func locate(anyOf repos: [RepoRef], in codeFolder: String) async -> GitClone? {
        let rewrites = await URLRewrites.load(using: git, in: URL(fileURLWithPath: codeFolder, isDirectory: true))
        var cache = storage.load(Cache.self, forKey: Self.cacheKey) ?? Cache()
        for repo in repos {
            guard let path = cache.paths[repo.cacheKey] else { continue }
            if WorkspacePath.contains(codeFolder, path),
               let clone = Self.clone(at: path, rewrites: rewrites),
               clone.remote(for: repo) != nil {
                return clone
            }
        }

        let found = scan(codeFolder, rewrites: rewrites)
        cache.paths = [:]
        var ssh = 0, https = 0
        for (clone, _) in found {
            for remote in clone.remotes {
                guard let github = remote.github else { continue }
                if github.transport == .ssh { ssh += 1 } else if github.transport == .https { https += 1 }
                if cache.paths[github.repo.cacheKey] == nil, let best = Self.best(found, for: github.repo) {
                    cache.paths[github.repo.cacheKey] = best.path
                }
            }
        }
        cache.prefersSSH = ssh + https == 0 ? nil : ssh >= https
        storage.save(cache, forKey: Self.cacheKey)
        return repos.lazy.compactMap { Self.best(found, for: $0) }.first
    }

    /// Clones `repo` into `codeFolder` (a canonical path).
    func clone(_ repo: RepoRef, into codeFolder: String) async throws -> GitClone {
        var cache = storage.load(Cache.self, forKey: Self.cacheKey) ?? Cache()
        let url = cache.prefersSSH == true
            ? "git@github.com:\(repo.fullName).git"
            : "https://github.com/\(repo.fullName).git"
        let destination = Self.freeDestination(for: repo, in: codeFolder)
        try await git.check(
            ["clone", "--", url, destination], in: URL(fileURLWithPath: codeFolder, isDirectory: true), timeout: 1800
        )
        let path = WorkspacePath.canonical(destination)
        guard let clone = Self.clone(at: path, rewrites: URLRewrites()) else {
            throw WorkspaceError.git("git clone didn't leave a repo at \(WorkspaceError.abbreviated(path)).")
        }
        cache.paths[repo.cacheKey] = path
        storage.save(cache, forKey: Self.cacheKey)
        return clone
    }

    /// Main working trees under `codeFolder`, breadth-first, with their depth.
    func scan(_ codeFolder: String, rewrites: URLRewrites) -> [(clone: GitClone, depth: Int)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [(clone: GitClone, depth: Int)] = []
        var queue: [(path: String, depth: Int)] = [(codeFolder, 0)]
        var next = 0
        while next < queue.count, next < Self.maxFolders {
            let (path, depth) = queue[next]
            next += 1
            if let clone = Self.clone(at: path, rewrites: rewrites) {
                found.append((clone, depth))
                continue
            }
            guard depth < Self.maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: Array(keys)
                  )
            else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                let name = child.lastPathComponent
                if name.hasPrefix(".") {
                    if name != ".git", let clone = Self.clone(at: child.path, rewrites: rewrites) {
                        found.append((clone, depth + 1))
                    }
                } else if values.isPackage != true, !name.hasSuffix(".worktrees"), !Self.skippedFolders.contains(name) {
                    queue.append((child.path, depth + 1))
                }
            }
        }
        return found
    }

    /// The clone at `path` with its remotes; nil unless it's a main working tree.
    static func clone(at path: String, rewrites: URLRewrites) -> GitClone? {
        guard WorkspacePath.isMainWorkTree(path) else { return nil }
        let config = URL(fileURLWithPath: path).appendingPathComponent(".git/config")
        let remotes = GitConfigFile.remotes(at: config).map { remote in
            GitRemote(
                name: remote.name, url: remote.url,
                github: GitHubRemoteURL(remote.url) ?? GitHubRemoteURL(rewrites.apply(remote.url))
            )
        }
        return GitClone(path: path, remotes: remotes)
    }

    private static func best(_ found: [(clone: GitClone, depth: Int)], for repo: RepoRef) -> GitClone? {
        func rank(_ entry: (clone: GitClone, depth: Int)) -> (Int, Int, String) {
            (entry.clone.remote(for: repo)?.name == "origin" ? 0 : 1, entry.depth, entry.clone.path)
        }
        return found
            .filter { $0.clone.remote(for: repo) != nil }
            .min { rank($0) < rank($1) }?
            .clone
    }

    /// <folder>/<repo>, else <folder>/<owner>-<repo>, else that with -2, -3…
    private static func freeDestination(for repo: RepoRef, in folder: String) -> String {
        func safe(_ name: String) -> String {
            let cleaned = name.replacingOccurrences(of: "/", with: "-")
            return cleaned.allSatisfy { $0 == "." } ? "repo" : cleaned
        }
        let owned = safe("\(repo.owner)-\(repo.name)")
        var candidates = [safe(repo.name), owned]
        candidates += (2...99).map { "\(owned)-\($0)" }
        let name = candidates.first { !WorkspacePath.exists(folder + "/" + $0) } ?? "\(owned)-\(UUID().uuidString.prefix(8))"
        return folder + "/" + name
    }
}
