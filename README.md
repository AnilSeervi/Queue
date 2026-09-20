# Queue

macOS menu bar app that surfaces the GitHub items that need *you*: review requests, mentions, your open PRs with CI/review state, assigned issues, and a small stats view. Native SwiftUI + AppKit.

The menu bar badge counts only what needs you — review requests + mentions + your failing PRs — never raw notification volume. All tabs cover **all** your repos; there is nothing to configure.

## Install

Download `Queue-vX.Y.Z.zip` from the [latest release](https://github.com/AnilSeervi/Queue/releases/latest), unzip, and move `Queue.app` to `/Applications`. The app is ad-hoc signed (no Apple developer certificate), so macOS quarantines the download — clear it once, then open:

```sh
xattr -dr com.apple.quarantine /Applications/Queue.app
open /Applications/Queue.app
```

Then follow [Live mode](#live-mode) below to sign in.

## Build & run

Requires macOS 14+ and Swift 5.10+ (Command Line Tools are enough; no Xcode project).

```sh
swift build                 # compile
scripts/bundle.sh           # produce build/Queue.app (release, ad-hoc signed)
open build/Queue.app
```

After a rebuild, quit the running app first (right-click the status icon → Quit Queue) — `open` won't relaunch a running instance.

### Cutting a release

Push a version tag; CI builds the app and attaches the zip to a GitHub release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

### Demo mode

Runs against fixture data — no GitHub account needed:

```sh
QUEUE_DEMO=1 swift run                      # signed-in demo data
QUEUE_DEMO=1 QUEUE_ONBOARDING=1 swift run   # exercise the sign-in card
QUEUE_SHOW=1 …                              # auto-open the panel on launch
QUEUE_SNAPSHOT=<dir> …                      # render every surface to PNGs and exit
```

### Live mode

Queue signs in with the GitHub OAuth **device flow**: the panel shows a code, you authorize it in the browser, done. One-time developer setup — create a GitHub OAuth app (github.com/settings/developers; **enable Device Flow** on it) and provide its client ID:

```sh
defaults write com.queueapp.Queue githubClientID <your-client-id>
# or, when launching the binary directly (open doesn't forward env vars):
QUEUE_GITHUB_CLIENT_ID=<your-client-id> ./build/Queue.app/Contents/MacOS/Queue
```

Tokens live in your Keychain (`com.queueapp.Queue`), never on disk or in logs. Scopes: `repo read:org` (approve/merge need the classic `repo` scope). OAuth apps with "Expire user authorization tokens" enabled work out of the box — the refresh token is stored and access tokens auto-renew on 401.

Dev-build note: the bundle is ad-hoc signed, so macOS asks for Keychain access once per rebuild ("Always Allow" holds for that build). A real signing identity (Apple Development certificate) makes it permanent.

## Using it

- Click the status icon (or press **⌥⇧G**) to toggle the panel.
- Hover a row for actions: Approve / Merge / Re-run checks / ⌥ Copy branch / snooze / open on GitHub.
- Snoozing hides an item until 9 AM the next day; the clock button in the tab bar snoozes everything until tomorrow; Undo wakes everything snoozed.
- The footer shows **Up next** — the oldest item waiting on you, clickable to open on GitHub — plus time since last refresh (click to refresh) and the Settings gear.
- Right-click (or ⌃-click) the status icon: Refresh Now · Settings… · Quit.
- Settings: account/sign-out, launch at login, refresh interval (poll every 1–15 min), badge style (count/dot/off), red-dot alert when CI fails on your PR.

## Layout

- `Sources/Queue/Models.swift`, `AppState.swift` — data model, observable store, snooze/badge/up-next logic, `QueueDataSource`/`AuthProvider` contracts
- `Sources/Queue/Support/Theme.swift` — design tokens (dark + light)
- `Sources/Queue/Views/` — panel UI (tabs, rows, stats, settings window, onboarding)
- `Sources/Queue/GitHub/` — device-flow auth, token refresh, Keychain, REST/GraphQL client, live data source
- `Sources/Queue/App/` — status item, floating panel, global hotkey, snapshot renderer
- `Sources/Queue/MockData.swift` — fixtures (demo mode + previews)

## Known gaps

- Global shortcut is fixed at ⌥⇧G (the Settings chip is display-only).
- "Review turnaround" stat shows — in live mode (not derivable from the API cheaply); activity bars are live-mode zeros for the same reason.
- Launch-at-login requires running from the bundled `Queue.app` (SMAppService).
