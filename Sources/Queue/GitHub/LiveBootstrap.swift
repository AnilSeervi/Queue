import Foundation

// Live-mode bootstrap: wires AppState to the GitHub integration (device-flow
// or token auth + GitHubDataSource). A Keychain token means a previous
// sign-in — start signed in with the cached login; otherwise start at the
// sign-in card (spec 1e) with the auth provider ready. AppDelegate starts the
// refresh timer and the first refresh for both.
enum LiveBootstrap {
    @MainActor static func makeState(settings: SettingsStore) -> AppState {
        let dataSource = GitHubDataSource(settings: settings)
        let state: AppState

        if Keychain.load() != nil {
            let login = UserDefaults.standard.string(forKey: "githubLogin") ?? "you"
            state = AppState(
                settings: settings,
                dataSource: dataSource,
                auth: .signedIn(username: login)
            )
        } else {
            state = AppState(settings: settings, dataSource: dataSource, auth: .signedOut)
        }

        // AppState.signOut() calls authProvider.signOut(), which clears the
        // Keychain token and cached "githubLogin".
        let auth = GitHubAuth(settings: settings)
        state.authProvider = auth
        // No OAuth client ID (a downloaded release): open on token entry
        // rather than a device code that can't be fetched.
        if case .signedOut = state.auth, !auth.supportsDeviceFlow {
            state.tokenEntryActive = true
        }
        return state
    }
}
