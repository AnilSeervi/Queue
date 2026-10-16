import Foundation

// Checking a PR's branch out on a git worktree beside your clone, for
// "open in editor":
//
//   ~/Projects/queue                        your checkout, left as it is
//   ~/Projects/queue.worktrees/fix-retry    the PR's branch, added by Queue
//
// In your clone Queue runs only `git fetch` and `git worktree add` (which
// also creates the worktree's local branch), plus read-only commands; the
// only other writes are to what Queue made: fast-forwarding its own
// worktrees, cleanup's (below), and clearing git's record of a Queue
// worktree whose folder was deleted by hand. A branch that's already checked
// out — in your checkout or any worktree — opens where it is.
//
// Every open fetches the PR's head. A worktree and branch Queue made, with
// no uncommitted changes, is fast-forwarded to it (`git merge --ff-only`);
// anything else stays as it is, and the open says it's behind.
//
// The local branch:
//   - same-repo PR: the PR's branch name, tracking <remote>/<branch>; one you
//     already have is used as it is, never reset;
//   - your PR from a fork your clone has a remote for: the same, tracking the
//     fork's branch, so you can push;
//   - anyone else's fork PR: GitHub's refs/pull/<n>/head on a new branch
//     queue/pr-<n>, in folder pr-<n> (queue/<owner>-<repo>-pr-<n> when this
//     clone's queue/pr-<n> is another repo's PR #n).
// A local branch of the PR's name that tracks something else (an unrelated
// branch of yours, your main tracking upstream's) stays out of it: the PR
// gets queue/pr-<n> instead, as does a branch name git can't use locally
// ("-x"). Folders are named after the branch ("feat/x" → feat-x), with -2,
// -3… when the name is taken.
//
// A stack (GitHub's stacked PRs, all in one repo) shares one worktree,
// <clone>.worktrees/stack-<n>: opening any of its PRs switches it to that
// PR's branch when it has no uncommitted changes, else it stays where it is
// and says so. It goes only once every PR of the stack is merged or closed.
//
// Every worktree Queue adds is recorded (UserDefaults "worktreeRegistry"),
// with each PR it was opened for. cleanup() removes the ones whose PRs were
// all merged or closed, never any other, and only when nothing can be lost:
// no uncommitted changes, no untracked files, no commits that are neither on
// a remote branch nor part of what Queue checked out. It uses plain
// `git worktree remove`, which refuses anything unsafe itself. A branch Queue
// created goes with `git branch -d`, or `-D` once the same check finds every
// commit on it on GitHub (squash merges, fork PRs' branches); one that fails
// both is left to you. Ignored files are where git's "clean" falls short:
// `git worktree remove` deletes them. Regenerable ones (node_modules, build
// output, caches, editor state, .DS_Store) go with the worktree; any other
// ignored file — a .env, a local config — keeps it, with the reason logged.

/// What ensureWorktree is doing, for a progress line.
enum WorkspaceStep: Hashable, Sendable {
    case findingClone
    case cloning(RepoRef)
    case fetching(branch: String)
    case addingWorktree
    case switching(branch: String)

    var label: String {
        switch self {
        case .findingClone: return "Finding your clone…"
        case .cloning(let repo): return "Cloning \(repo.fullName)…"
        case .fetching(let branch): return "Fetching \(branch)…"
        case .addingWorktree: return "Creating worktree…"
        case .switching(let branch): return "Switching to \(branch)…"
        }
    }
}

/// What ensureWorktree opened.
struct OpenedWorktree: Hashable, Sendable {
    var url: URL
    /// Why it isn't at the PR's latest commit, when it isn't (a sentence).
    var note: String?
}

/// A worktree Queue added.
struct WorktreeRecord: Codable, Hashable, Sendable {
    /// Canonical path of the worktree's folder.
    var path: String
    var clonePath: String
    /// The PR it was last opened for.
    var repo: RepoRef
    var number: Int
    /// Every PR it was opened for (one branch can back a closed PR and its
    /// successor); cleanup waits until all of them are merged or closed.
    var prNodeIDs: [String]
    /// The local branch Queue checked out in it.
    var branch: String
    /// Queue created `branch` (cleanup may then delete it).
    var createdBranch: Bool
    /// The PR head Queue fetched for it. Commits up to it came from GitHub,
    /// so cleanup counts them as pushed even where no remote-tracking branch
    /// has them (a fork PR's refs/pull head, a branch deleted after merging).
    var checkoutSHA: String
    var createdAt: Date
    /// The stack this worktree serves, when it's one: every PR of the stack
    /// opens here, on its own branch. nil for a single PR's worktree.
    var stackID: String? = nil
    /// Every PR of that stack as of the last open; cleanup waits for all.
    var stackMemberIDs: [String]? = nil
    /// Branches of the stack's PRs: the worktree may be on any of them.
    var stackBranches: [String]? = nil

    /// The PRs whose merge or close cleanup waits for.
    var awaitedPRNodeIDs: [String] { Array(Set(prNodeIDs + (stackMemberIDs ?? []))).sorted() }
}

/// A local branch Queue created, until Queue deletes it (or leaves it to you).
struct CreatedBranch: Codable, Hashable, Sendable {
    var clonePath: String
    var branch: String
    var repo: RepoRef
    var number: Int
    var prNodeIDs: [String]
    /// The PR head Queue last put on it (see WorktreeRecord.checkoutSHA).
    var checkoutSHA: String?
}

struct WorktreeRegistry: Codable, Hashable {
    var worktrees: [WorktreeRecord] = []
    var branches: [CreatedBranch] = []
    /// "<clone>.worktrees" folders Queue created (removed once empty).
    var folders: [String] = []
}

/// What cleanup() did about one worktree or branch of a merged / closed PR.
struct CleanupResult: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// Worktree removed; see `branchDeleted` for its branch.
        case removedWorktree
        /// Worktree left alone (`reason` says why).
        case keptWorktree
        /// A branch Queue created, whose worktree was already gone, deleted.
        case deletedBranch
        /// That branch kept: `git branch -d` refused (`reason`).
        case keptBranch
    }

    var repo: RepoRef
    var number: Int
    /// The worktree's folder; nil for a branch on its own.
    var path: String?
    var branch: String
    var action: Action
    var branchDeleted = false
    /// Why something was left alone; nil when everything went.
    var reason: String?
}

/// One entry of `git worktree list --porcelain -z`.
struct WorktreeEntry: Hashable, Sendable {
    /// Canonical path.
    var path: String
    var head: String?
    /// Short branch name; nil when detached.
    var branch: String?
    var isBare = false
    var isLocked = false
    /// Its folder is gone (git still has its record).
    var isPrunable = false

    /// "key value" fields with a NUL after each, and an empty field after
    /// each worktree.
    static func parse(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            guard !field.isEmpty else {
                if let entry = current { entries.append(entry) }
                current = nil
                continue
            }
            let key = field.prefix { $0 != " " }
            let value = String(field.dropFirst(key.count + 1))
            switch key {
            case "worktree": current = WorktreeEntry(path: WorkspacePath.canonical(value))
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        if let entry = current { entries.append(entry) }
        return entries
    }
}

actor WorktreeManager {
    static let shared = WorktreeManager()
    static let registryKey = "worktreeRegistry"

    private let git: GitRunner
    private let storage: WorkspaceStorage
    private let locator: CloneLocator
    private var registry: WorktreeRegistry {
        didSet { if registry != oldValue { storage.save(registry, forKey: Self.registryKey) } }
    }

    init(git: GitRunner = GitRunner(), storage: WorkspaceStorage = .standard) {
        self.git = git
        self.storage = storage
        locator = CloneLocator(git: git, storage: storage)
        registry = storage.load(WorktreeRegistry.self, forKey: Self.registryKey) ?? WorktreeRegistry()
    }

    // MARK: Opening

    /// A folder with the PR's branch checked out: where it already is, else
    /// a new worktree beside your clone (cloning the repo into `codeFolder`
    /// first if you have no clone), brought up to the PR's latest commit
    /// where that's safe. `onStep` reports progress as it goes.
    func ensureWorktree(
        for ref: BranchRef, codeFolder: URL, onStep: (@Sendable (WorkspaceStep) -> Void)? = nil
    ) async throws -> OpenedWorktree {
        await acquire()
        defer { release() }
        let folder = WorkspacePath.canonical(codeFolder.path)
        guard WorkspacePath.isDirectory(folder) else { throw WorkspaceError.codeFolderMissing(codeFolder.path) }
        // Clones would land inside that repo's checkout.
        guard WorkspacePath.repo(containing: folder) == nil else { throw WorkspaceError.codeFolderInRepo(codeFolder.path) }
        forgetMissing()

        onStep?(.findingClone)
        let clone = try await findOrClone(ref, in: folder, onStep: onStep)
        let plan = try await checkoutPlan(for: ref, in: clone)
        var worktrees = try await worktreeList(at: clone.path)
        var holder = worktrees.first { $0.branch == plan.localBranch }
        if let missing = holder, missing.isPrunable || !WorkspacePath.isDirectory(missing.path) {
            try await releaseMissing(missing, branch: plan.localBranch, clone: clone)
            worktrees = try await worktreeList(at: clone.path)
            holder = nil
        }

        onStep?(.fetching(branch: ref.branch))
        if holder == nil, let stack = ref.stack,
           let shared = registry.worktrees.first(where: { $0.stackID == stack.id && $0.clonePath == clone.path }),
           worktrees.contains(where: { $0.path == shared.path && !$0.isPrunable }) {
            return try await openInStackWorktree(shared, for: ref, stack: stack, plan: plan, clone: clone, onStep: onStep)
        }
        if let holder {
            adopt(holder.path, branch: plan.localBranch, for: ref, clonePath: clone.path)
            let url = URL(fileURLWithPath: holder.path, isDirectory: true)
            // It opens as it is when GitHub can't be reached, or the branch
            // is gone after merging.
            let sha: String
            do {
                sha = try await fetch(plan.source, in: clone)
            } catch let error as WorkspaceError {
                return OpenedWorktree(url: url, note: "Couldn't check for newer commits: \(error.localizedDescription)")
            }
            return OpenedWorktree(url: url, note: await catchUp(holder.path, branch: plan.localBranch, to: sha, clone: clone))
        }
        let sha = try await fetch(plan.source, in: clone)
        let reusing = try await localBranchExists(plan.localBranch, in: clone)
        let folderExisted = WorkspacePath.exists(clone.worktreesFolder)
        let folderName = ref.stack.map { "stack-\($0.number)" } ?? plan.folderName
        let path = freeWorktreePath(named: folderName, in: clone, taken: worktrees.map(\.path))

        onStep?(.addingWorktree)
        try await addWorktree(at: path, plan: plan, sha: sha, reusing: reusing, clone: clone)

        let ids = ref.prNodeID.map { [$0] } ?? []
        if !reusing {
            registry.branches.append(CreatedBranch(
                clonePath: clone.path, branch: plan.localBranch, repo: ref.repo, number: ref.number,
                prNodeIDs: ids, checkoutSHA: sha
            ))
        }
        if !folderExisted { registry.folders.append(clone.worktreesFolder) }
        registry.worktrees.append(WorktreeRecord(
            path: path, clonePath: clone.path, repo: ref.repo, number: ref.number, prNodeIDs: ids,
            branch: plan.localBranch, createdBranch: createdByQueue(plan.localBranch, in: clone.path),
            checkoutSHA: sha, createdAt: Date(),
            stackID: ref.stack?.id,
            stackMemberIDs: ref.stack?.members.map(\.nodeID),
            stackBranches: ref.stack.map { Array(Set($0.members.map(\.branch) + [plan.localBranch])).sorted() }
        ))
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard reusing else { return OpenedWorktree(url: url) }
        // An existing branch is checked out as it is: catch it up.
        adopt(nil, branch: plan.localBranch, for: ref, clonePath: clone.path)
        return OpenedWorktree(url: url, note: await catchUp(path, branch: plan.localBranch, to: sha, clone: clone))
    }

    /// Ties Queue's worktree at `path` and its branch (where Queue made them)
    /// to `ref`'s PR as well as the ones they were opened for before.
    private func adopt(_ path: String?, branch: String, for ref: BranchRef, clonePath: String) {
        var updated = registry
        func tied(_ ids: [String]) -> [String] {
            guard let id = ref.prNodeID, !ids.contains(id) else { return ids }
            return ids + [id]
        }
        for index in updated.worktrees.indices where updated.worktrees[index].path == path {
            updated.worktrees[index].prNodeIDs = tied(updated.worktrees[index].prNodeIDs)
            updated.worktrees[index].repo = ref.repo
            updated.worktrees[index].number = ref.number
        }
        for index in updated.branches.indices
        where updated.branches[index].clonePath == clonePath && updated.branches[index].branch == branch {
            updated.branches[index].prNodeIDs = tied(updated.branches[index].prNodeIDs)
            updated.branches[index].repo = ref.repo
            updated.branches[index].number = ref.number
        }
        registry = updated
    }

    /// Opens `ref`'s PR in its stack's shared worktree: fetches it, then
    /// switches the worktree to its branch — unless the worktree has
    /// uncommitted changes, which would ride along or block, so it stays on
    /// the branch it's on and says so.
    private func openInStackWorktree(
        _ shared: WorktreeRecord, for ref: BranchRef, stack: StackInfo, plan: CheckoutPlan, clone: GitClone,
        onStep: (@Sendable (WorkspaceStep) -> Void)?
    ) async throws -> OpenedWorktree {
        let url = URL(fileURLWithPath: shared.path, isDirectory: true)
        let sha = try await fetch(plan.source, in: clone)
        tie(shared.path, toStack: stack, branch: plan.localBranch, for: ref, clonePath: clone.path)
        let current = (try? await git.check(["rev-parse", "--abbrev-ref", "HEAD"], in: url).value) ?? shared.branch
        let changes = try await git.check(["status", "--porcelain", "--untracked-files=no"], in: url).value
        guard changes.isEmpty else {
            return OpenedWorktree(url: url, note: "Stayed on \(current): the stack's worktree has uncommitted changes. Commit or stash them to switch to #\(ref.number).")
        }
        let reusing = try await localBranchExists(plan.localBranch, in: clone)
        onStep?(.switching(branch: plan.localBranch))
        func arguments(track: Bool) -> [String] {
            // isUsableBranchName rules out names git would read as options.
            if reusing { return ["switch", "--no-guess", plan.localBranch] }
            if case .branch(let remote, let name) = plan.source {
                return ["switch", track ? "--track" : "--no-track", "-c", plan.localBranch, "refs/remotes/\(remote.name)/\(name)"]
            }
            return ["switch", "--no-track", "-c", plan.localBranch, sha]
        }
        var output = try await git.run(arguments(track: true), in: url, timeout: 300)
        if !output.succeeded, output.stderr.contains("cannot set up tracking information") {
            output = try await git.run(arguments(track: false), in: url, timeout: 300)
        }
        guard output.succeeded else { throw WorkspaceError(gitFailure: output) }

        if !reusing {
            registry.branches.append(CreatedBranch(
                clonePath: clone.path, branch: plan.localBranch, repo: ref.repo, number: ref.number,
                prNodeIDs: ref.prNodeID.map { [$0] } ?? [], checkoutSHA: sha
            ))
        }
        if let index = registry.worktrees.firstIndex(where: { $0.path == shared.path }) {
            registry.worktrees[index].branch = plan.localBranch
            registry.worktrees[index].createdBranch = createdByQueue(plan.localBranch, in: clone.path)
            if !reusing { registry.worktrees[index].checkoutSHA = sha }
        }
        guard reusing else { return OpenedWorktree(url: url) }
        adopt(nil, branch: plan.localBranch, for: ref, clonePath: clone.path)
        return OpenedWorktree(url: url, note: await catchUp(shared.path, branch: plan.localBranch, to: sha, clone: clone))
    }

    /// adopt() for a stack's shared worktree, which also follows the stack:
    /// its PRs (cleanup waits for all of them) and their branches.
    private func tie(_ path: String, toStack stack: StackInfo, branch: String, for ref: BranchRef, clonePath: String) {
        adopt(path, branch: branch, for: ref, clonePath: clonePath)
        guard let index = registry.worktrees.firstIndex(where: { $0.path == path }) else { return }
        var record = registry.worktrees[index]
        record.stackMemberIDs = Array(Set((record.stackMemberIDs ?? []) + stack.members.map(\.nodeID))).sorted()
        record.stackBranches = Array(Set((record.stackBranches ?? []) + stack.members.map(\.branch) + [branch])).sorted()
        registry.worktrees[index] = record
    }

    /// Brings the worktree at `path` up to the PR's head `sha` when it's
    /// behind it: a branch Queue created, in a worktree Queue added, with no
    /// uncommitted changes, is fast-forwarded (git refuses to overwrite
    /// untracked files itself). Otherwise it stays as it is; returns why.
    private func catchUp(_ path: String, branch: String, to sha: String, clone: GitClone) async -> String? {
        let worktree = URL(fileURLWithPath: path, isDirectory: true)
        func isAncestor(_ a: String, of b: String) async -> Bool {
            (try? await git.run(["merge-base", "--is-ancestor", a, b], in: worktree))?.succeeded == true
        }
        guard let head = try? await git.check(["rev-parse", "--verify", "HEAD^{commit}"], in: worktree).value,
              head != sha,
              !(await isAncestor(sha, of: head))   // ahead: your commits on top of the PR
        else { return nil }
        let behind = "isn't at the PR's latest commit"
        guard registry.worktrees.contains(where: { $0.path == path }) else {
            return "\(WorkspaceError.abbreviated(path)) \(behind): Queue doesn't update your own checkouts."
        }
        guard createdByQueue(branch, in: clone.path) else {
            return "Your branch \(branch) \(behind): Queue doesn't move branches it didn't create."
        }
        guard let status = try? await git.check(["status", "--porcelain", "--untracked-files=no"], in: worktree),
              status.value.isEmpty
        else { return "Its worktree \(behind): it has uncommitted changes." }
        if await isAncestor(head, of: sha) {
            do {
                try await git.check(["merge", "--ff-only", "--quiet", sha], in: worktree, timeout: 300)
            } catch {
                return "Its worktree \(behind): \(error.localizedDescription)"
            }
        } else {
            // The PR was rewritten (a force-push, or GitHub rebasing a stack
            // after a lower PR merged). Move the branch to the new head only
            // when every commit on it came from GitHub, so nothing of yours
            // is dropped; `reset --keep` refuses to touch local changes too.
            let fetched = [registry.branches.first { $0.clonePath == clone.path && $0.branch == branch }?.checkoutSHA,
                           registry.worktrees.first { $0.path == path }?.checkoutSHA].compactMap { $0 }
            guard let unpushed = try? await git.check(["rev-list", "--count", "HEAD", "--not", "--remotes"] + fetched, in: worktree).value,
                  unpushed == "0"
            else { return "Its worktree \(behind): it has commits the PR doesn't (was the PR force-pushed?)." }
            do {
                try await git.check(["reset", "--keep", "--quiet", sha], in: worktree, timeout: 300)
            } catch {
                return "Its worktree \(behind): \(error.localizedDescription)"
            }
        }
        if let index = registry.worktrees.firstIndex(where: { $0.path == path }) {
            registry.worktrees[index].checkoutSHA = sha
        }
        if let index = registry.branches.firstIndex(where: { $0.clonePath == clone.path && $0.branch == branch }) {
            registry.branches[index].checkoutSHA = sha
        }
        return nil
    }

    // MARK: Cleanup

    /// PR node ids with worktrees or branches Queue made; look up their
    /// lifecycles and pass them to cleanup().
    func trackedPRNodeIDs() -> [String] {
        forgetMissing()
        return Set(registry.worktrees.flatMap(\.awaitedPRNodeIDs) + registry.branches.flatMap(\.prNodeIDs)).sorted()
    }

    /// The worktrees Queue added (and hasn't removed).
    func records() -> [WorktreeRecord] {
        forgetMissing()
        return registry.worktrees
    }

    /// Removes what Queue made for PRs that `lifecycles` says are merged or
    /// closed, where it's safe (see the top of the file). Ids it doesn't
    /// mention are left for next time.
    func cleanup(lifecycles: [String: PRLifecycle]) async -> [CleanupResult] {
        await acquire()
        defer { release() }
        forgetMissing()
        // Every PR it was opened for is merged or closed.
        func isFinished(_ ids: [String]) -> Bool {
            // (A stack's worktree passes awaitedPRNodeIDs: all its PRs.)
            !ids.isEmpty && ids.allSatisfy { id in lifecycles[id].map { $0 != .open } ?? false }
        }
        func key(_ clonePath: String, _ branch: String) -> String { clonePath + "\0" + branch }

        var results: [CleanupResult] = []
        // Branches remove() already tried to delete, not to try twice.
        var tried: Set<String> = []
        for record in registry.worktrees where isFinished(record.awaitedPRNodeIDs) {
            let created = registry.branches.first { $0.clonePath == record.clonePath && $0.branch == record.branch }
            let result = await remove(record, deleting: created.flatMap { isFinished($0.prNodeIDs) ? $0 : nil })
            if result.action == .removedWorktree { tried.insert(key(record.clonePath, record.branch)) }
            results.append(result)
        }
        for branch in registry.branches where isFinished(branch.prNodeIDs) {
            let inUse = registry.worktrees.contains { $0.clonePath == branch.clonePath && $0.branch == branch.branch }
            guard !inUse, !tried.contains(key(branch.clonePath, branch.branch)), registry.branches.contains(branch)
            else { continue }
            // Its worktree's folder was deleted by hand: git still counts the
            // branch as checked out there until that record is cleared.
            let clone = URL(fileURLWithPath: branch.clonePath, isDirectory: true)
            if let holder = try? await worktreeList(at: branch.clonePath).first(where: { $0.branch == branch.branch }),
               holder.isPrunable, !holder.isLocked,
               WorkspacePath.contains(branch.clonePath + ".worktrees", holder.path) {
                _ = try? await git.run(["worktree", "remove", "--", holder.path], in: clone)
            }
            let reason = await deleteCreatedBranch(branch)
            guard reason != Self.alreadyGone else { continue }
            results.append(CleanupResult(
                repo: branch.repo, number: branch.number, path: nil, branch: branch.branch,
                action: reason == nil ? .deletedBranch : .keptBranch, branchDeleted: reason == nil, reason: reason
            ))
        }
        return results
    }

    /// Removes `record`'s worktree, then `branch` (its branch, when Queue
    /// created it and its PRs are all finished too).
    private func remove(_ record: WorktreeRecord, deleting branch: CreatedBranch?) async -> CleanupResult {
        var result = CleanupResult(
            repo: record.repo, number: record.number, path: record.path, branch: record.branch, action: .keptWorktree
        )
        func keep(_ reason: String, forget: Bool = false) -> CleanupResult {
            if forget { registry.worktrees.removeAll { $0.path == record.path } }
            result.reason = reason
            return result
        }
        guard WorkspacePath.isMainWorkTree(record.clonePath) else {
            return keep("its clone isn't at \(WorkspaceError.abbreviated(record.clonePath)) any more", forget: true)
        }
        let worktree = URL(fileURLWithPath: record.path, isDirectory: true)
        do {
            guard let entry = try await worktreeList(at: record.clonePath).first(where: { $0.path == record.path }) else {
                return keep("it's no longer a git worktree", forget: true)
            }
            if entry.isLocked { return keep("it's locked (git worktree lock)") }
            // A stack's worktree may be on any of the stack's branches.
            let expected = Set([record.branch] + (record.stackBranches ?? []))
            guard let current = entry.branch, expected.contains(current) else {
                return keep("it has \(entry.branch ?? "a detached HEAD") checked out now")
            }
            let status = try await git.check(["status", "--porcelain", "--untracked-files=all"], in: worktree)
            if !status.value.isEmpty { return keep("it has uncommitted changes or untracked files") }
            let ignored = try await keptIgnoredPaths(in: worktree)
            if !ignored.isEmpty {
                let shown = ignored.prefix(3).joined(separator: ", ") + (ignored.count > 3 ? " +\(ignored.count - 3) more" : "")
                return keep("it has ignored files Queue won't delete: \(shown)")
            }
            let unpushed = try await git.check(
                ["rev-list", "--count", "HEAD", "--not", "--remotes", record.checkoutSHA], in: worktree
            ).value
            guard unpushed == "0" else {
                return keep(unpushed == "1" ? "it has a commit that isn't on GitHub" : "it has \(unpushed) commits that aren't on GitHub")
            }
            try await git.check(
                ["worktree", "remove", "--", record.path],
                in: URL(fileURLWithPath: record.clonePath, isDirectory: true), timeout: 120
            )
        } catch {
            return keep(error.localizedDescription)
        }

        registry.worktrees.removeAll { $0.path == record.path }
        removeWorktreesFolderIfEmpty(for: record.clonePath)
        result.action = .removedWorktree
        if let branch {
            let reason = await deleteCreatedBranch(branch, alsoFromGitHub: record.checkoutSHA)
            result.branchDeleted = reason == nil
            result.reason = reason == Self.alreadyGone ? nil : reason
        }
        return result
    }

    private static let alreadyGone = "already deleted"

    /// Ignored folders that are safe to lose with a worktree: dependencies,
    /// build products, caches and editor state, all regenerated on demand.
    static let disposableIgnoredFolders: Set<String> = [
        "node_modules", ".build", "build", "dist", "out", "target", ".next", ".nuxt", ".svelte-kit",
        ".turbo", ".parcel-cache", ".cache", "coverage", ".nyc_output", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".tox", ".venv", "venv", ".gradle", "DerivedData", ".swiftpm",
        "Pods", ".idea", ".vscode", ".fleet", ".zed",
    ]

    static func isDisposableIgnored(_ path: String) -> Bool {
        let isFolder = path.hasSuffix("/")
        let name = (isFolder ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init) ?? path
        if isFolder { return disposableIgnoredFolders.contains(name) }
        return name == ".DS_Store" || name.hasSuffix(".pyc") || name.hasSuffix(".log")
    }

    /// Ignored paths in `worktree` that cleanup must not delete. Wholly
    /// ignored folders are listed once ("node_modules/"), not file by file.
    private func keptIgnoredPaths(in worktree: URL) async throws -> [String] {
        let output = try await git.check(
            ["status", "--porcelain", "-z", "--ignored=traditional", "--untracked-files=normal"], in: worktree
        ).stdout
        return output.split(separator: "\0").compactMap { entry -> String? in
            guard entry.hasPrefix("!! ") else { return nil }
            let path = String(entry.dropFirst(3))
            return Self.isDisposableIgnored(path) ? nil : path
        }
    }

    /// Deletes a branch Queue created: `git branch -d`, which keeps a branch
    /// that isn't merged into its upstream (or the clone's HEAD). That misses
    /// squash and rebase merges, and a fork PR's queue/pr-<n> has no
    /// upstream, so when every commit on it is on a remote branch or part of
    /// a PR head Queue fetched (`alsoFromGitHub`), `git branch -D`. Returns
    /// why it's kept, nil once it's gone. A kept branch is left to you: it's
    /// no longer tracked, so cleanup doesn't retry it every time.
    private func deleteCreatedBranch(_ created: CreatedBranch, alsoFromGitHub sha: String? = nil) async -> String? {
        let clone = URL(fileURLWithPath: created.clonePath, isDirectory: true)
        func forget() { registry.branches.removeAll { $0.clonePath == created.clonePath && $0.branch == created.branch } }
        let output: GitOutput
        do {
            output = try await git.run(["branch", "-d", "--", created.branch], in: clone)
            if output.succeeded {
                forget()
                return nil
            }
            if output.stderr.contains("not found") {
                forget()
                return Self.alreadyGone
            }
            let fromGitHub = Set([created.checkoutSHA, sha].compactMap { $0 })
            if !fromGitHub.isEmpty,
               let tip = try? await git.check(["rev-parse", "--verify", "refs/heads/\(created.branch)^{commit}"], in: clone).value,
               try await git.run(["rev-list", "--count", tip, "--not", "--remotes"] + fromGitHub.sorted(), in: clone).value == "0",
               // Refuses a branch checked out anywhere.
               try await git.run(["branch", "-D", "--", created.branch], in: clone).succeeded {
                forget()
                return nil
            }
        } catch {
            // Git didn't run: next time.
            return error.localizedDescription
        }
        forget()
        return "kept the branch: " + (WorkspaceError(gitFailure: output).errorDescription ?? "git branch -d failed")
    }

    private func createdByQueue(_ branch: String, in clonePath: String) -> Bool {
        registry.branches.contains { $0.clonePath == clonePath && $0.branch == branch }
    }

    /// Removes "<clone>.worktrees" once its last worktree has gone, if Queue
    /// created it. rmdir only ever removes an empty folder.
    private func removeWorktreesFolderIfEmpty(for clonePath: String) {
        let folder = clonePath + ".worktrees"
        guard registry.folders.contains(folder) else { return }
        if rmdir(folder) == 0 || errno == ENOENT { registry.folders.removeAll { $0 == folder } }
    }

    /// Drops records whose folder (or clone) no longer exists.
    private func forgetMissing() {
        var kept = registry
        kept.worktrees.removeAll { !WorkspacePath.isDirectory($0.path) }
        kept.branches.removeAll { !WorkspacePath.isMainWorkTree($0.clonePath) }
        kept.folders.removeAll { !WorkspacePath.isDirectory($0) }
        if kept != registry { registry = kept }
    }

    // MARK: Checkout

    private struct CheckoutPlan {
        enum Source {
            /// refs/heads/<name> on `remote`, tracked as <remote>/<name>.
            case branch(remote: GitRemote, name: String)
            /// refs/pull/<number>/head on the base repo's remote.
            case pullRef(remote: GitRemote, number: Int)
        }
        var localBranch: String
        var folderName: String
        var source: Source
    }

    private func findOrClone(
        _ ref: BranchRef, in folder: String, onStep: (@Sendable (WorkspaceStep) -> Void)?
    ) async throws -> GitClone {
        // Your own fork PR: a clone of just the fork will do.
        var repos = [ref.repo]
        if ref.isFromFork, ref.isMine, let headRepo = ref.headRepo { repos.append(headRepo) }
        if let clone = await locator.locate(anyOf: repos, in: folder) { return clone }
        onStep?(.cloning(ref.repo))
        return try await locator.clone(ref.repo, into: folder)
    }

    private func checkoutPlan(for ref: BranchRef, in clone: GitClone) async throws -> CheckoutPlan {
        let folder = Self.folderName(for: ref.branch) ?? "pr-\(ref.number)"
        // Same-repo PR, or your own from a fork your clone has a remote for.
        var head: (remote: GitRemote, repo: RepoRef)?
        if !ref.isFromFork {
            guard let remote = clone.remote(for: ref.repo) else { throw WorkspaceError.noRemote(ref.repo.fullName) }
            head = (remote, ref.repo)
        } else if ref.isMine, let headRepo = ref.headRepo, let fork = clone.remote(for: headRepo) {
            head = (fork, headRepo)
        }
        if let head {
            let named = Self.isUsableBranchName(ref.branch)
                ? try await canUseItsName(ref, headRepo: head.repo, in: clone) : false
            return CheckoutPlan(
                localBranch: named ? ref.branch : try await queueBranch(for: ref, in: clone), folderName: folder,
                source: .branch(remote: head.remote, name: ref.branch)
            )
        }
        guard let base = clone.remote(for: ref.repo) else { throw WorkspaceError.noRemote(ref.repo.fullName) }
        return CheckoutPlan(
            localBranch: try await queueBranch(for: ref, in: clone), folderName: "pr-\(ref.number)",
            source: .pullRef(remote: base, number: ref.number)
        )
    }

    /// The PR can have a local branch of its own branch's name: there's none
    /// yet, or the one there is tracks that branch on a remote for
    /// `headRepo`, or is the one Queue made for this repo's PR before (which
    /// can't track anything in a clone whose fetch refspec doesn't cover it).
    private func canUseItsName(_ ref: BranchRef, headRepo: RepoRef, in clone: GitClone) async throws -> Bool {
        let local = ref.branch
        guard try await localBranchExists(local, in: clone) else { return true }
        if registry.branches.contains(where: {
            $0.clonePath == clone.path && $0.branch == local && $0.repo.isSameRepo(as: ref.repo)
        }) { return true }
        let remote = try await git.run(["config", "--get", "branch.\(local).remote"], in: clone.url).value
        let merge = try await git.run(["config", "--get", "branch.\(local).merge"], in: clone.url).value
        let tracked = clone.remotes.first { $0.name == remote }?.github?.repo
        return merge == "refs/heads/\(ref.branch)" && tracked?.isSameRepo(as: headRepo) == true
    }

    /// The branch Queue checks the PR out on when it can't use the PR's own
    /// name: the one it made for this PR in this clone before, else
    /// queue/pr-<n> — or queue/<owner>-<repo>-pr-<n> when there's a
    /// queue/pr-<n> here already: another repo's PR #n (a clone with remotes
    /// for a fork and its upstream), or one Queue no longer knows about.
    private func queueBranch(for ref: BranchRef, in clone: GitClone) async throws -> String {
        let made = registry.branches.filter { $0.clonePath == clone.path && $0.branch.hasPrefix("queue/") }
        if let mine = made.first(where: { $0.number == ref.number && $0.repo.isSameRepo(as: ref.repo) }) {
            return mine.branch
        }
        let short = "queue/pr-\(ref.number)"
        if !made.contains(where: { $0.branch == short }), !(try await localBranchExists(short, in: clone)) { return short }
        // Owners are letters, digits and "-"; a repo's "." could make "..".
        let repo = ref.repo.name.replacingOccurrences(of: ".", with: "-")
        return "queue/\(ref.repo.owner)-\(repo)-pr-\(ref.number)"
    }

    /// Fetches the branch's commits; returns the commit to check out.
    private func fetch(_ source: CheckoutPlan.Source, in clone: GitClone) async throws -> String {
        switch source {
        case .branch(let remote, let name):
            // An explicit refspec, so the remote-tracking branch exists even
            // in a clone whose fetch refspec doesn't cover it.
            let tracking = "refs/remotes/\(remote.name)/\(name)"
            try await git.check(
                ["fetch", "--no-tags", "--", remote.name, "+refs/heads/\(name):\(tracking)"], in: clone.url, timeout: 300
            )
            return try await git.check(["rev-parse", "--verify", "\(tracking)^{commit}"], in: clone.url).value
        case .pullRef(let remote, let number):
            // The head's SHA, then exactly that commit: no reading FETCH_HEAD,
            // which a fetch of your own could overwrite meanwhile.
            let listing = try await git.check(
                ["ls-remote", "--", remote.name, "refs/pull/\(number)/head"], in: clone.url, timeout: 120
            ).value
            let sha = String(listing.prefix { !$0.isWhitespace })
            guard sha.count >= 40, sha.allSatisfy(\.isHexDigit) else { throw WorkspaceError.pullRefMissing(number) }
            try await git.check(["fetch", "--no-tags", "--", remote.name, sha], in: clone.url, timeout: 300)
            return sha
        }
    }

    private func addWorktree(at path: String, plan: CheckoutPlan, sha: String, reusing: Bool, clone: GitClone) async throws {
        func arguments(track: Bool) -> [String] {
            if reusing { return ["worktree", "add", "--", path, plan.localBranch] }
            if case .branch(let remote, let name) = plan.source {
                return ["worktree", "add", track ? "--track" : "--no-track", "-b", plan.localBranch,
                        "--", path, "refs/remotes/\(remote.name)/\(name)"]
            }
            return ["worktree", "add", "--no-track", "-b", plan.localBranch, "--", path, sha]
        }
        do {
            var output = try await git.run(arguments(track: true), in: clone.url, timeout: 600)
            // A remote whose fetch refspec doesn't map the branch can't be tracked.
            if !output.succeeded, output.stderr.contains("cannot set up tracking information") {
                output = try await git.run(arguments(track: false), in: clone.url, timeout: 600)
            }
            if !output.succeeded { throw WorkspaceError(gitFailure: output) }
        } catch {
            // A failing post-checkout hook fails the command after the
            // worktree is made; that worktree is fine to open.
            let made = try await worktreeList(at: clone.path)
                .contains { $0.path == WorkspacePath.canonical(path) && $0.branch == plan.localBranch }
            if !made { throw error }
        }
    }

    /// `branch` is held by a worktree whose folder is gone. If it's one of
    /// Queue's (in this clone's .worktrees folder), `git worktree remove`
    /// clears git's record of it (there's no folder left to remove).
    private func releaseMissing(_ holder: WorktreeEntry, branch: String, clone: GitClone) async throws {
        guard WorkspacePath.contains(clone.worktreesFolder, holder.path), !holder.isLocked else {
            throw WorkspaceError.branchInMissingWorktree(branch: branch, path: holder.path)
        }
        try await git.check(["worktree", "remove", "--", holder.path], in: clone.url)
    }

    private func worktreeList(at clonePath: String) async throws -> [WorktreeEntry] {
        let output = try await git.check(
            ["worktree", "list", "--porcelain", "-z"], in: URL(fileURLWithPath: clonePath, isDirectory: true)
        )
        return WorktreeEntry.parse(output.stdout)
    }

    private func localBranchExists(_ branch: String, in clone: GitClone) async throws -> Bool {
        try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: clone.url).succeeded
    }

    /// <clone>.worktrees/<name>, or <name>-2, -3… when that's taken on disk
    /// or by a worktree whose folder is missing.
    private func freeWorktreePath(named name: String, in clone: GitClone, taken: [String]) -> String {
        let base = clone.worktreesFolder + "/" + name
        var candidate = base
        var suffix = 2
        while WorkspacePath.exists(candidate) || taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: Names

    /// Git can't make a local branch called this ("-x" reads as an option).
    static func isUsableBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name != "HEAD" && !name.contains("@{")
    }

    /// A folder name for a branch: "feat/Fix retry!" → "feat-Fix-retry".
    /// Letters, digits, ".", "_" and "-" stay; nil if nothing does.
    static func folderName(for branch: String) -> String? {
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var name = String(String.UnicodeScalarView(branch.unicodeScalars.map { kept.contains($0) ? $0 : "-" }))
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        let edges = CharacterSet(charactersIn: "-.")
        name = String(name.trimmingCharacters(in: edges).prefix(60)).trimmingCharacters(in: edges)
        return name.isEmpty ? nil : name
    }

    // MARK: One at a time

    // Two clicks on one PR, or a cleanup during a checkout, would otherwise
    // interleave at their awaits.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the next waiter (still busy), or frees it.
    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
