import AppKit
import SwiftUI

// Onboarding (spec 1e) — two popover-sized cards, 320px wide, always dark.
// PanelRootView swaps this in while not signed in and draws the panel chrome
// (radius / border / material); this view draws its own near-opaque dark bg.

// MARK: - Local constants (spec 1e values not covered by Theme.swift)

private enum OB {
    static let cardWidth: CGFloat = 320
    static let cardPadding: CGFloat = 24
    /// Card bg rgba(30,31,36,0.97) — more opaque than the panel tint.
    static let cardBackground = Color(.sRGB, red: 30/255, green: 31/255, blue: 36/255, opacity: 0.97)

    static let monoURLFont = Font.system(size: 11.5, design: .monospaced)     // github.com/login/device
    static let primaryButtonFont = Font.system(size: 12.5, weight: .semibold) // Open GitHub / Start watching
    static let footnoteFont = Font.system(size: 10.5)                         // Keychain note / "3 of 5 repos"
    static let repoRowFont = Font.system(size: 11, design: .monospaced)       // repo fullName
    static let openPRsFont = Font.system(size: 10)                            // "62 open PRs"

    static let crossfade = Animation.easeOut(duration: 0.15)
}

// MARK: - Onboarding root

struct OnboardingView: View {
    @EnvironmentObject var state: AppState

    /// 1 = sign-in card (signedOut placeholder or deviceFlow), 2 = repo picker.
    private var stepIndex: Int {
        if case .pickingRepos = state.auth { return 2 }
        return 1
    }

    var body: some View {
        ZStack {
            if state.tokenEntryActive {
                TokenStepView()
                    .transition(.opacity)
            } else {
            switch state.auth {
            case .signedOut:
                SignInStepView(info: nil)
                    .transition(.opacity)
                    .onAppear { state.beginSignIn() } // idempotent-guarded in AppState
            case .deviceFlow(let info):
                SignInStepView(info: info)
                    .transition(.opacity)
            case .pickingRepos(let repos):
                RepoPickerStepView(repos: repos, initialSelection: initialSelection(for: repos))
                    .transition(.opacity)
            case .signedIn:
                EmptyView() // PanelRootView won't show onboarding then.
            }
            }
        }
        .padding(OB.cardPadding)
        .frame(width: OB.cardWidth)
        .background(OB.cardBackground)
        .environment(\.colorScheme, .dark) // spec 1e: onboarding is always dark
        .animation(OB.crossfade, value: stepIndex)
        .animation(OB.crossfade, value: state.tokenEntryActive)
    }

    /// settings.watchedRepos ∩ repos; fallback: first 3.
    private func initialSelection(for repos: [WatchableRepo]) -> Set<String> {
        let available = Set(repos.map(\.id))
        let fromSettings = state.settings.watchedRepos.intersection(available)
        return fromSettings.isEmpty ? Set(repos.prefix(3).map(\.id)) : fromSettings
    }
}

// MARK: - Step 1 — Sign in (device flow)

private struct SignInStepView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    /// nil while the device flow hasn't produced a code yet → placeholder.
    var info: DeviceFlowInfo?

    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            PRGlyph(color: .white, size: 28, lineWidth: 1.8)

            Text("Sign in to GitHub")
                .font(DSFont.onboardingTitle())
                .foregroundStyle(.white)
                .padding(.top, 14)

            VStack(spacing: 2) {
                Text("Enter this code at")
                    .font(DSFont.onboardingBody())
                Text("github.com/login/device")
                    .font(OB.monoURLFont)
            }
            .foregroundStyle(Color.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.top, 6)

            // Device code in a dashed box, full card width. Click to copy.
            Button(action: copyCode) {
                Text(info?.userCode ?? "····-····")
                    .font(DSFont.deviceCode())
                    .tracking(3)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                Color.white.opacity(0.2),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if copied {
                            Text("Copied")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x7EE2A0))
                                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .padding(5)
                                .transition(.opacity)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(info == nil)
            .help("Copy code")
            .padding(.top, 16)

            // Primary: white bg, #1d1d1f text.
            Button {
                if let info { state.open(info.verificationURL) }
            } label: {
                Text("Open GitHub")
                    .font(OB.primaryButtonFont)
                    .foregroundStyle(Color(hex: 0x1D1D1F))
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            Text("Read + review scopes only. Token stays in your Keychain.")
                .font(OB.footnoteFont)
                .foregroundStyle(Color.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            // Sign-in failures (e.g. missing OAuth client ID) surface here
            // with a retry — otherwise the card sits on the placeholder code
            // with no explanation.
            if let error = state.inlineError {
                VStack(spacing: 6) {
                    Text(error)
                        .font(OB.footnoteFont)
                        .foregroundStyle(Color(hex: 0xFF7369))
                        .multilineTextAlignment(.center)
                    Button {
                        state.beginSignIn()
                    } label: {
                        Text("Try again")
                            .font(OB.footnoteFont.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
            }

            Button {
                state.showTokenEntry()
            } label: {
                Text("Use a personal access token instead")
                    .font(OB.footnoteFont.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
    }

    private func copyCode() {
        guard let code = info?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyGeneration += 1
        let generation = copyGeneration
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard generation == copyGeneration else { return }
            withAnimation(.easeOut(duration: 0.12)) { copied = false }
        }
    }
}

// MARK: - Alternative — Personal access token

private struct TokenStepView: View {
    @EnvironmentObject var state: AppState
    @State private var token = ""
    @FocusState private var fieldFocused: Bool

    /// Classic-token form prefilled with the scopes Queue needs.
    private static let createURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Queue")!

    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && !state.isSigningInWithToken
    }

    var body: some View {
        VStack(spacing: 0) {
            PRGlyph(color: .white, size: 28, lineWidth: 1.8)

            Text("Use an access token")
                .font(DSFont.onboardingTitle())
                .foregroundStyle(.white)
                .padding(.top, 14)

            Text("Create a classic token with the repo and read:org scopes, then paste it below.")
                .font(DSFont.onboardingBody())
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            // Secondary: opens GitHub's new-token form with scopes prefilled.
            Button {
                state.open(Self.createURL)
            } label: {
                Text("Create token on GitHub")
                    .font(OB.primaryButtonFont)
                    .foregroundStyle(.white)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            // Token field + Paste fallback (works without a ⌘V menu path).
            HStack(spacing: 8) {
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("Paste")
                        .font(OB.footnoteFont.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .padding(.top, 10)

            Button(action: submit) {
                Text(state.isSigningInWithToken ? "Signing in…" : "Sign in")
                    .font(OB.primaryButtonFont)
                    .foregroundStyle(Color(hex: 0x1D1D1F))
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(canSubmit ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(.top, 10)

            if let error = state.tokenError {
                Text(error)
                    .font(OB.footnoteFont)
                    .foregroundStyle(Color(hex: 0xFF7369))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }

            Text("Stored in your Keychain only.")
                .font(OB.footnoteFont)
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.top, 12)

            Button {
                state.showCodeEntry()
            } label: {
                Text("Sign in with a code instead")
                    .font(OB.footnoteFont.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard canSubmit else { return }
        let value = token
        token = ""   // never keep the secret in view state longer than needed
        state.signInWithToken(value)
    }
}

// MARK: - Step 2 — Choose what to watch

private struct RepoPickerStepView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    var repos: [WatchableRepo]
    @State private var selected: Set<String>

    init(repos: [WatchableRepo], initialSelection: Set<String>) {
        self.repos = repos
        _selected = State(initialValue: initialSelection)
    }

    var body: some View {
        let ds = DS(scheme)
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose what to watch")
                .font(DSFont.onboardingTitleSmall())
                .foregroundStyle(.white)
            Text("For the main-branch CI strip — change anytime in Settings.")
                .font(DSFont.onboardingBody())
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 3)

            VStack(spacing: 6) {
                ForEach(repos) { repo in
                    RepoPickRow(repo: repo, isSelected: selected.contains(repo.id)) {
                        withAnimation(OB.crossfade) {
                            if selected.contains(repo.id) {
                                selected.remove(repo.id)
                            } else {
                                selected.insert(repo.id)
                            }
                        }
                    }
                }
            }
            .padding(.top, 12)

            HStack(spacing: 8) {
                Text("\(selected.count) of \(repos.count) repo\(repos.count == 1 ? "" : "s")")
                    .font(OB.footnoteFont)
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer(minLength: 0)
                Button {
                    state.completeOnboarding(selectedRepos: selected)
                } label: {
                    Text("Start watching")
                        .font(OB.primaryButtonFont)
                        .foregroundStyle(.white)
                        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .background(ds.link, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
    }
}

/// One checklist row: 15px checkbox, mono repo name, right-aligned open-PR count.
private struct RepoPickRow: View {
    var repo: WatchableRepo
    var isSelected: Bool
    var toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                checkbox
                Text(repo.repo.fullName)
                    .font(OB.repoRowFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text("\(repo.openPRs) open PR\(repo.openPRs == 1 ? "" : "s")")
                    .font(OB.openPRsFont)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize()
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 1)
            )
            .opacity(isSelected ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var checkbox: some View {
        let ds = DS(scheme)
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ds.link)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
        .frame(width: 15, height: 15)
    }
}
