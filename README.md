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
- Click a row to open it on GitHub; on a failing PR the ✕ opens the failing check. Hover a row for actions: Approve / Merge (click twice: the button first asks, naming the repo's merge method) / Re-run checks / ⌥ Copy branch / ✓ Done (mentions: marks the thread read) / open.
- **Done** — the last row of Inbox and My PRs, "Done · N" — opens in place to list what you've dealt with in the last 7 days, newest first; click one to open it on GitHub. Inbox: reviews you submitted (approved, commented, requested changes — on github.com too), mentions you opened or marked ✓ Done, and review requests that went away without your review (merged, closed, or the request removed). My PRs: your merged PRs. A PR that asks for your review again moves back up to the open list. Reviews and merges come from GitHub; cleared mentions and vanished requests are noted on this Mac and cleared on sign-out.
- The footer shows **Up next** — the oldest item waiting on you, clickable to open on GitHub — plus time since last refresh (click to refresh) and the Settings gear.
- Right-click (or ⌃-click) the status icon for a menu: the version, what needs you (oldest first, click to open; "…and N more" and threads with new activity open the panel), then Open Queue · Refresh Now · Settings… · Quit Queue.
- **Notifications** (macOS Notification Center) for new review requests, comments that @-mention you, and your own PRs: CI failing, changes requested, merge conflicts, ready to merge. Settings has one toggle each for review requests, mentions and ready to merge; CI failing, changes requested and conflicts share one. Clicking one opens the item (a failed check opens its log; a mention is marked read); three or more at once collapse into a summary.
- **Stats**: your week (reviews given, PRs opened/merged, daily activity, streak), review requests by age, your PRs still waiting on reviewers, median time to first review, and CI pass rate with the most-failing check.
- Settings: account/sign-out, launch at login, refresh interval (poll every 1–15 min), notification toggles, badge style (count/dot/off), red dot when CI fails on your PR (shown next to the count in count mode).

## Layout

- `Sources/Queue/Models.swift`, `AppState.swift`, `DoneLog.swift` — data model, observable store, badge/up-next logic, the saved Done log, `QueueDataSource`/`AuthProvider` contracts
- `Sources/Queue/Support/Theme.swift` — design tokens (dark + light)
- `Sources/Queue/Views/` — panel UI (tabs, rows, stats, settings window, onboarding)
- `Sources/Queue/GitHub/` — device-flow auth, token refresh, Keychain, REST/GraphQL client, live data source
- `Sources/Queue/App/` — status item, floating panel, global hotkey, snapshot renderer
- `Sources/Queue/MockData.swift` — fixtures (demo mode + previews)

## Known gaps

- Global shortcut is fixed at ⌥⇧G (the Settings chip is display-only).
- Launch-at-login requires running from the bundled `Queue.app` (SMAppService).
