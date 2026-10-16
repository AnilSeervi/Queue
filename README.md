# Queue

macOS menu bar app that surfaces the GitHub items that need *you*: review requests, mentions, your open PRs with CI/review state, assigned issues, and a small stats view. Native SwiftUI + AppKit.

The menu bar badge counts only what needs you — review requests + mentions + your PRs with failing CI, changes requested or merge conflicts — never raw notification volume. All tabs cover **all** your repos; there is nothing to configure.

## Install

Download `Queue-vX.Y.Z.zip` from the [latest release](https://github.com/AnilSeervi/Queue/releases/latest), unzip, and move `Queue.app` to `/Applications`. The app is ad-hoc signed (no Apple developer certificate), so macOS quarantines the download — clear it once, then open:

```sh
xattr -dr com.apple.quarantine /Applications/Queue.app
open /Applications/Queue.app
```

Then sign in: Queue shows a code, you enter it on github.com, done (see [Live mode](#live-mode)).

## Build & run

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough; no Xcode project).

```sh
swift build                 # compile
scripts/bundle.sh           # produce build/Queue.app (release, ad-hoc signed)
open build/Queue.app
```

After a rebuild, quit the running app first (right-click the status icon → Quit Queue) — `open` won't relaunch a running instance.

### Cutting a release

Push a version tag; CI builds the app, launches it once in demo snapshot mode as a smoke test, and attaches the zip and its `.sha256` checksum to a GitHub release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Only plain `vX.Y.Z` tags release; anything else (`v1.0`, `v1.0.0-beta`) fails the workflow before it builds.

### Demo mode

Runs against fixture data — no GitHub account needed:

```sh
QUEUE_DEMO=1 swift run                      # signed-in demo data
QUEUE_DEMO=1 QUEUE_ONBOARDING=1 swift run   # exercise the sign-in card
QUEUE_SHOW=1 …                              # auto-open the panel on launch
QUEUE_SNAPSHOT=<dir> …                      # render every surface to PNGs and exit
```

### Live mode

Two ways to sign in, both on the sign-in card:

**Sign in with a code (default).** The panel shows a code; *Open GitHub* takes you to github.com/login/device, you enter it and authorize Queue, done. This uses Queue's own GitHub OAuth app, so there's nothing to set up. If your org restricts OAuth apps, an org admin has to approve Queue before that org's private repos show up — or use a personal access token instead.

**Personal access token.** Click *Use a personal access token instead*, hit *Create token on GitHub* (opens the classic-token form with `repo` and `read:org` prefilled), generate it, paste it, and sign in. It must be a classic token: fine-grained (`github_pat_…`) tokens can't read notifications or check runs, so Queue turns them away. If your org enforces SAML SSO, authorize the token for it on GitHub (*Configure SSO → Authorize*). Tokens without an expiry never need renewing; if you set one, Queue returns to the sign-in card when it lapses.

To test against a different OAuth app (Device Flow enabled), override the client ID:

```sh
defaults write com.queueapp.Queue githubClientID <your-client-id>
# or, when launching the binary directly (open doesn't forward env vars):
QUEUE_GITHUB_CLIENT_ID=<your-client-id> ./build/Queue.app/Contents/MacOS/Queue
```

OAuth app tokens don't expire unless the app turns on expiring tokens; if it does, Queue stores the refresh token and renews access tokens on 401.

Either way, the token lives in your Keychain (`com.queueapp.Queue`), never on disk or in logs. Scopes: `repo read:org` (approve/merge need the classic `repo` scope).

Dev-build note: the bundle is ad-hoc signed, so macOS asks for Keychain access once per rebuild ("Always Allow" holds for that build). A real signing identity (Apple Development certificate) makes it permanent.

## Using it

- Click the status icon (or press **⌥⇧G**) to toggle the panel.
- Click a row to open it on GitHub; on a failing PR the ✕ opens the failing check. Hover a row for its action icons (each has a tooltip): ✓ Approve (review requests) · Merge (ready PRs; click twice — the first click widens the icon into "Squash & merge?", naming the repo's merge method) · ↻ Re-run failed checks · Copy branch (review requests and your PRs) · `</>` Open in editor · ✓ Done (mentions: marks the thread read) · ↗ open on GitHub.
- **Open in editor** (`</>`, review requests and your PRs) checks the PR's branch out on a git worktree beside your clone and opens it in your editor: `~/Projects/queue` → `~/Projects/queue.worktrees/fix-webhook-retry`. The first time, Queue asks for your code folder (the folder your clones are in, not a repo itself). It finds the repo's clone there by its GitHub remote (https or ssh); if you have none, it clones the repo there first — over ssh if your other clones use ssh, else https — with your own git credentials, never Queue's GitHub token. Your checkout is left as it is: Queue only fetches and adds worktrees. A branch that's already checked out (in your clone or any worktree) opens where it is; someone else's fork PR is checked out from GitHub's `pull/<n>/head` as `queue/pr-<n>`, as is a PR whose branch name you already use for something else. Opening a PR again fetches it and fast-forwards Queue's worktree to its latest commit; one with uncommitted changes, or any checkout of yours, is left as it is, and Queue says it's behind. When a PR is merged or closed, Queue removes the worktrees it made for it, but only when nothing would be lost — no uncommitted changes, untracked files or unpushed commits, and no ignored files other than regenerable ones (`node_modules`, build output, caches, editor folders, `.DS_Store`). A worktree with, say, a `.env` stays. Needs git (Apple's command line tools or Homebrew's).
- **Stacked PRs** (GitHub's stacks: a chain of PRs in one repo, each building on the one below) sit together under "Stack · 3 PRs → main", top layer first, each with its place (`2/3`) — in My PRs and for review requests alike. Merge on a layer merges it and every open PR below it ("Squash & merge 2 PRs?"), through GitHub's stack merge; it shows once all of them are yours, approved, green and conflict-free. A stack opens in one shared worktree, `<repo>.worktrees/stack-<n>`: opening another of its PRs switches it to that PR's branch, unless it has uncommitted changes, in which case it stays where it is and Queue says so. After a lower PR merges and GitHub rebases the rest, opening a layer brings Queue's branch to the new head — only when every commit on it came from GitHub. The worktree goes once every PR of the stack is merged or closed, under the same rules as any other.
- **Done** — the last row of Inbox and My PRs, "Done · N" — opens in place to list what you've dealt with in the last 7 days, newest first; click one to open it on GitHub. Inbox: reviews you submitted (approved, commented, requested changes — on github.com too), mentions you opened or marked ✓ Done, and review requests that went away without your review (merged, closed, or the request removed). My PRs: your merged PRs. A PR that asks for your review again moves back up to the open list. Reviews and merges come from GitHub; cleared mentions and vanished requests are noted on this Mac and cleared on sign-out.
- The footer shows **Up next** — the oldest item waiting on you, clickable to open on GitHub — plus time since last refresh (click to refresh) and the Settings gear.
- Right-click (or ⌃-click) the status icon for a menu: the version, what needs you (oldest first, click to open; "…and N more" and threads with new activity open the panel), then Open Queue · Refresh Now · Settings… · Quit Queue.
- **Notifications** (macOS Notification Center) for new review requests, comments that @-mention you, and your own PRs: CI failing, changes requested, merge conflicts, ready to merge. Settings has one toggle each for review requests, mentions and ready to merge; CI failing, changes requested and conflicts share one. Clicking one opens the item (a failed check opens its log; a mention is marked read); three or more at once collapse into a summary.
- **Stats**: your week (reviews given, PRs opened/merged, daily activity, streak), review requests by age, your PRs still waiting on reviewers, median time to first review, and CI pass rate with the most-failing check.
- Settings: account/sign-out, launch at login, refresh interval (poll every 1–15 min), notification toggles, badge style (count/dot/off), red dot when CI fails on your PR (shown next to the count in count mode), and for Open in editor your code folder and the editor branches open in — whichever of VS Code, Cursor, Windsurf, Zed, Sublime Text, Nova, BBEdit, TextMate, the JetBrains IDEs or Xcode are installed (the first one found unless you pick another).

## Layout

- `Sources/Queue/Models.swift`, `AppState.swift`, `DoneLog.swift` — data model, observable store, badge/up-next logic, the saved Done log, `QueueDataSource`/`AuthProvider` contracts
- `Sources/Queue/Support/Theme.swift` — design tokens (dark + light)
- `Sources/Queue/Views/` — panel UI (tabs, rows, stats, settings window, onboarding)
- `Sources/Queue/GitHub/` — device-flow auth, token refresh, Keychain, REST/GraphQL client, live data source
- `Sources/Queue/Workspace/` — Open in editor: finding or cloning your clone, git worktrees and their cleanup, running git, the editor list
- `Sources/Queue/App/` — status item, floating panel, global hotkey, snapshot renderer
- `Sources/Queue/MockData.swift` — fixtures (demo mode + previews)

## Known gaps

- Global shortcut is fixed at ⌥⇧G (the Settings chip is display-only).
- Launch-at-login requires running from the bundled `Queue.app` (SMAppService).
