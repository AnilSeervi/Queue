import Foundation

// Where the workspace keeps its small JSON state between launches: the
// worktree registry and the clone cache. UserDefaults in the app; tests use
// a folder of files instead.

struct WorkspaceStorage: Sendable {
    var read: @Sendable (String) -> Data?
    var write: @Sendable (String, Data) -> Void

    static let standard = WorkspaceStorage(
        read: { UserDefaults.standard.data(forKey: $0) },
        write: { UserDefaults.standard.set($1, forKey: $0) }
    )

    /// One "<key>.json" file per key in `folder`.
    static func folder(_ folder: URL) -> WorkspaceStorage {
        WorkspaceStorage(
            read: { try? Data(contentsOf: folder.appendingPathComponent("\($0).json")) },
            write: { key, data in
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
            }
        )
    }

    func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = read(key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(key, data)
    }
}

// MARK: - Paths

enum WorkspacePath {
    /// `path` with symlinks resolved (realpath, so /tmp reads /private/tmp as
    /// git prints it); only standardized when it doesn't exist.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Anything at `path`, a dangling symlink included.
    static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// A main working tree: a folder whose .git is a folder. Linked worktrees
    /// and submodules have a .git file instead.
    static func isMainWorkTree(_ path: String) -> Bool {
        isDirectory(path + "/.git") && FileManager.default.fileExists(atPath: path + "/.git/config")
    }

    /// The repo `folder` (canonical) is, or is inside: the nearest folder
    /// holding a .git. Your home folder counts only as `folder` itself, so a
    /// dotfiles repo there doesn't rule out ~/Projects. nil when there's none.
    static func repo(containing folder: String) -> String? {
        let home = canonical(NSHomeDirectory())
        var path = folder
        while path == folder || path != home {
            if exists(path + "/.git") { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
        return nil
    }

    /// `path` is `folder` or inside it (both canonical).
    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Two spellings of the same location.
    static func same(_ a: String, _ b: String) -> Bool {
        canonical(a) == canonical(b)
    }
}
