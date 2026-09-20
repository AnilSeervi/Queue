import Foundation

// Live-mode bootstrap: wires AppState to the GitHub integration (device-flow
// auth + GitHubDataSource). A Keychain token means a previous sign-in — start
// signed in with the cached login and refresh immediately; otherwise start at
// onboarding step 1 (spec 1e) with the auth provider ready.
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
            state.startRefreshTimer()
        } else {
            state = AppState(settings: settings, dataSource: dataSource, auth: .signedOut)
        }

        // AppState.signOut() calls authProvider.signOut(), which clears the
        // Keychain token and cached "githubLogin".
        state.authProvider = GitHubAuth(settings: settings)
        if case .signedIn = state.auth {
            Task {
                await state.refresh()
                // Settings shows live repo chips, not the demo placeholder list.
                await state.reloadAvailableRepos()
            }
        }
        return state
    }
}
