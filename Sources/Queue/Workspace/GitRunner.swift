import Foundation

// Runs git for "open in editor": finding your clone, fetching a PR's branch,
// adding and removing worktrees. Arguments go in as an argv array, never
// through a shell, so branch names and paths can hold anything (callers put
// "--" before refs and paths that could look like options).
//
// Git sees a minimal environment: enough of Queue's own for your git config,
// credential helpers and SSH agent to work as they do in Terminal, nothing
// of Queue's GitHub token (git always authenticates as you), and
// GIT_TERMINAL_PROMPT=0 so a missing credential fails at once instead of
// waiting on a prompt nobody can see.

// MARK: - Errors

enum WorkspaceError: LocalizedError, Hashable {
    /// No git: Apple's command line tools aren't installed (and no Homebrew git).
    case gitMissing
    /// The chosen code folder doesn't exist (renamed, or a volume that's gone).
    case codeFolderMissing(String)
    /// The chosen code folder is a repo, or inside one: clones would land in
    /// that checkout.
    case codeFolderInRepo(String)
    /// GitHub refused your git credentials (or the repo isn't visible to them).
    case authFailed
    /// SSH has never seen github.com's host key and can't ask you about it.
    case hostKeyUnverified
    /// GitHub couldn't be reached; git's own line.
    case network(String)
    /// A git command ran past its timeout and was stopped.
    case timedOut(String)
    /// The PR's branch isn't on GitHub (deleted after merging, or renamed).
    case branchGone(String)
    /// GitHub has no refs/pull/<n>/head for the PR.
    case pullRefMissing(Int)
    /// The branch is checked out in a worktree Queue didn't make.
    case checkedOutElsewhere(branch: String, path: String)
    /// The branch is checked out in a worktree whose folder is missing (on a
    /// disconnected drive, or deleted without `git worktree remove`).
    case branchInMissingWorktree(branch: String, path: String)
    /// The clone has no remote for the repo the branch is in.
    case noRemote(String)
    /// None of the editors Queue knows is installed.
    case noEditor
    /// The editor wouldn't open the folder.
    case editorFailed(String)
    /// Anything else: git's own message.
    case git(String)

    var errorDescription: String? {
        switch self {
        case .gitMissing:
            return "Git isn't installed. Run xcode-select --install in Terminal to get Apple's command line tools."
        case .codeFolderMissing(let path):
            return "Your code folder (\(Self.abbreviated(path))) isn't there. Choose it again in Settings."
        case .codeFolderInRepo(let path):
            return "\(Self.abbreviated(path)) is a git repo, or inside one. Choose the folder your clones are in, like ~/Projects."
        case .authFailed:
            return "GitHub turned down your git credentials. Check that fetching this repo works in Terminal — Queue uses your own git sign-in."
        case .hostKeyUnverified:
            return "SSH doesn't trust github.com yet. Run ssh -T git@github.com once in Terminal."
        case .network(let detail):
            return detail.isEmpty ? "Couldn't reach GitHub." : "Couldn't reach GitHub: \(detail)"
        case .timedOut(let command):
            return "git \(command) took too long and was stopped."
        case .branchGone(let branch):
            return "The branch \(branch) is no longer on GitHub."
        case .pullRefMissing(let number):
            return "GitHub has no commits for PR #\(number)."
        case .checkedOutElsewhere(let branch, let path):
            return "\(branch) is already checked out at \(Self.abbreviated(path))."
        case .branchInMissingWorktree(let branch, let path):
            return "\(branch) is checked out in a worktree that's missing (\(Self.abbreviated(path))). Reconnect it, or run git worktree prune."
        case .noRemote(let repo):
            return "Your clone has no remote for \(repo)."
        case .noEditor:
            return "No supported editor is installed."
        case .editorFailed(let message):
            return message
        case .git(let message):
            return message
        }
    }

    /// "~/Projects/queue" for paths in your home folder.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Reads git's stderr for the failures worth explaining; anything else
    /// keeps git's own last line.
    init(gitFailure output: GitOutput) {
        let text = output.stderr
        let lower = text.lowercased()
        func mentions(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }

        if mentions(["xcrun: error", "invalid active developer path", "no developer tools were found"]) {
            self = .gitMissing
        } else if mentions(["host key verification failed"]) {
            self = .hostKeyUnverified
        } else if mentions([
            "could not resolve host", "could not resolve hostname", "failed to connect", "couldn't connect to server",
            "connection timed out", "operation timed out", "network is unreachable", "connection refused",
            "connection reset", "ssl certificate problem", "no route to host",
        ]) {
            self = .network(Self.message(from: output))
        } else if mentions([
            "authentication failed", "could not read username", "could not read password", "terminal prompts disabled",
            "invalid username or password", "permission denied (publickey", "repository not found",
            "returned error: 401", "returned error: 403", "could not read from remote repository",
        ]) {
            self = .authFailed
        } else if let ref = Self.capture(#"couldn't find remote ref (\S+)"#, in: text)?.first {
            if let number = Self.capture(#"^refs/pull/(\d+)/head$"#, in: ref)?.first.flatMap({ Int($0) }) {
                self = .pullRefMissing(number)
            } else {
                self = .branchGone(ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref)
            }
        } else if let found = Self.capture(#"'(.+)' is already (?:used by worktree|checked out) at '(.+)'"#, in: text),
                  found.count == 2 {
            self = .checkedOutElsewhere(branch: found[0], path: found[1])
        } else if mentions(["unable to access"]) {
            self = .network(Self.message(from: output))
        } else {
            self = .git(Self.message(from: output))
        }
    }

    /// Git's last "fatal:" / "error:" line (else its last line), without the
    /// prefix: "invalid reference: main".
    private static func message(from output: GitOutput) -> String {
        let lines = output.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last
        guard var message = line else {
            return "git \(GitRunner.subcommand(of: output.arguments)) failed (exit \(output.status))."
        }
        for prefix in ["fatal: ", "error: ", "fatal:", "error:"] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count))
            break
        }
        return message.prefix(1).uppercased() + message.dropFirst()
    }

    /// The capture groups of the first match of `pattern`, or nil.
    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Runner

struct GitOutput: Sendable {
    var arguments: [String]
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }
    /// stdout trimmed, for commands that print one value.
    var value: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct GitRunner: Sendable {
    /// Variables kept from Queue's environment (a GUI app gets launchd's).
    /// HOME finds your git config; SSH_AUTH_SOCK your SSH agent.
    static let inherited = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME", "__CF_USER_TEXT_ENCODING",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
    ]
    /// Prepended to PATH, which for a GUI app is only /usr/bin:/bin:/usr/sbin:/sbin:
    /// where credential helpers (gh, git-credential-manager) and git-lfs live.
    static let toolFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// /usr/bin/git is a stub that needs Apple's developer tools (Command Line
    /// Tools or Xcode) and offers to install them when they're missing; without
    /// them, Homebrew's git when there is one.
    static let defaultExecutable: URL? = {
        let fileManager = FileManager.default
        let developerFolders = [
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
            try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
            "/Library/Developer/CommandLineTools",
            "/Applications/Xcode.app/Contents/Developer",
        ].compactMap { $0 }
        if fileManager.isExecutableFile(atPath: "/usr/bin/git"),
           developerFolders.contains(where: { fileManager.isExecutableFile(atPath: $0 + "/usr/bin/git") }) {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    let executable: URL?
    let environment: [String: String]

    /// `overrides` replace or add variables (tests point HOME at a scratch
    /// folder with its own git config).
    init(executable: URL? = GitRunner.defaultExecutable, overrides: [String: String] = [:]) {
        self.executable = executable
        let own = ProcessInfo.processInfo.environment
        var environment = own.filter { Self.inherited.contains($0.key) }
        let path = (own["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (Self.toolFolders.filter { !path.contains($0) } + path).joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Don't take the index lock for `git status` (your editor may be running git too).
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // English messages, which WorkspaceError reads.
        environment["LC_ALL"] = "C"
        environment.merge(overrides) { _, new in new }
        self.environment = environment
    }

    /// Runs git and returns its output whatever the exit status. Throws only
    /// when git can't run, times out (`.timedOut`), or the task is cancelled
    /// (git and its helpers are stopped either way).
    func run(_ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 60) async throws -> GitOutput {
        guard let executable else { throw WorkspaceError.gitMissing }
        let running = RunningGit()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runBlocking(executable, arguments, directory, timeout, running)
                    })
                }
            }
        } onCancel: {
            running.stop(timedOut: false)
        }
    }

    /// run(), throwing a WorkspaceError when git exits non-zero.
    @discardableResult
    func check(_ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 60) async throws -> GitOutput {
        let output = try await run(arguments, in: directory, timeout: timeout)
        guard output.succeeded else { throw WorkspaceError(gitFailure: output) }
        return output
    }

    private func runBlocking(
        _ executable: URL, _ arguments: [String], _ directory: URL?, _ timeout: TimeInterval, _ running: RunningGit
    ) throws -> GitOutput {
        if let directory, !WorkspacePath.isDirectory(directory.path) {
            throw WorkspaceError.git("Couldn't run git in \(WorkspaceError.abbreviated(directory.path)): the folder isn't there.")
        }
        // git -C rather than a working directory for the process: posix_spawn's
        // chdir action differs across macOS versions.
        let argv = (directory.map { ["-C", $0.path] } ?? []) + arguments
        let stdout = try PipeEnds(), stderr = try PipeEnds()
        do {
            try running.launch {
                try Self.spawn(executable, argv, environment, stdout: stdout.write, stderr: stderr.write)
            }
        } catch {
            stdout.closeAll()
            stderr.closeAll()
            if error is CancellationError { throw error }
            let place = directory.map { " in \(WorkspaceError.abbreviated($0.path))" } ?? ""
            throw WorkspaceError.git("Couldn't run git\(place): \(error.localizedDescription)")
        }
        close(stdout.write)
        close(stderr.write)
        // Read both pipes as git writes, so neither fills up and stalls it.
        let out = PipeReader(stdout.read), errors = PipeReader(stderr.read)
        let deadline = DispatchWorkItem { running.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let status = running.wait()
        deadline.cancel()
        // Something git started can outlive it holding the pipes (a hook's
        // background job): a moment for the rest of the output, no more.
        let drain = DispatchTime.now() + 2
        let outData = out.collect(by: drain), errorData = errors.collect(by: drain)

        if running.didTimeOut { throw WorkspaceError.timedOut(Self.subcommand(of: arguments)) }
        if running.wasCancelled { throw CancellationError() }
        return GitOutput(
            arguments: arguments,
            status: status,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self)
        )
    }

    /// "fetch" for ["-c", "x=y", "fetch", …]: the first argument that isn't
    /// an option or an option's value.
    static func subcommand(of arguments: [String]) -> String {
        var rest = arguments[...]
        while let first = rest.first, first.hasPrefix("-") {
            rest = rest.dropFirst(first == "-c" || first == "-C" ? 2 : 1)
        }
        return rest.first ?? ""
    }

    /// posix_spawn rather than Process, which hands the child decomposed
    /// (NFD) UTF-8 — a branch named "ünïcode" would no longer match GitHub's.
    /// Git starts in a session of its own — its own process group, and no
    /// terminal for ssh to ask a passphrase on — with only stdin (/dev/null),
    /// stdout and stderr open.
    private static func spawn(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}

/// A pipe; both ends close-on-exec (posix_spawn's dup2 gives git its own copy).
private struct PipeEnds {
    let read: Int32
    let write: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        read = fds[0]
        write = fds[1]
    }

    func closeAll() {
        close(read)
        close(write)
    }
}

/// One run()'s git process, for its timeout and task cancellation.
private final class RunningGit: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var finished = false
    private var timedOut = false
    private var cancelled = false

    var didTimeOut: Bool { lock.withLock { timedOut } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    /// Starts git (`spawn` returns its pid) unless the task was already cancelled.
    func launch(_ spawn: () throws -> pid_t) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            pid = try spawn()
        }
    }

    /// Waits for git to exit and reaps it; its exit status (128 + n when
    /// killed by signal n).
    func wait() -> Int32 {
        let pid = lock.withLock { self.pid }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        lock.withLock { finished = true }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Signals git's whole process group, so its ssh / git-remote-https
    /// helpers (which hold the pipes open) stop too. Only until git is
    /// reaped: its pid can't be reused before then.
    func stop(timedOut: Bool) {
        let target: pid_t = lock.withLock {
            if timedOut { self.timedOut = true } else { cancelled = true }
            return finished ? 0 : pid
        }
        guard target > 0 else { return }
        kill(-target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            lock.withLock { if !finished { kill(-target, SIGKILL) } }
        }
    }
}

/// Reads a pipe to its end on a dispatch queue; collect() can stop early.
private final class PipeReader: @unchecked Sendable {
    private let channel: DispatchIO
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(_ fd: Int32) {
        let queue = DispatchQueue(label: "Queue.git-output")
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] finished, chunk, _ in
            if let chunk, !chunk.isEmpty { lock.withLock { data.append(contentsOf: chunk) } }
            if finished { done.signal() }
        }
    }

    /// What was read by the time the pipe closed, or by `deadline` (then
    /// reading stops). Closes the pipe.
    func collect(by deadline: DispatchTime) -> Data {
        if done.wait(timeout: deadline) == .timedOut {
            channel.close(flags: .stop)
            done.wait()
        } else {
            channel.close()
        }
        return lock.withLock { data }
    }
}
