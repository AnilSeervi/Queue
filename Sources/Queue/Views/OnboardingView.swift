import AppKit
import SwiftUI

// Onboarding (spec 1e) — popover-sized sign-in cards (device code or access
// token), 320px wide, always dark.
// PanelRootView swaps this in while not signed in and draws the panel chrome
// (radius / border / material); this view draws its own near-opaque dark bg.

// MARK: - Local constants (spec 1e values not covered by Theme.swift)

private enum OB {
    static let cardWidth: CGFloat = 320
    static let cardPadding: CGFloat = 24
    /// Card bg rgba(30,31,36,0.97) — more opaque than the panel tint.
    static let cardBackground = Color(.sRGB, red: 30/255, green: 31/255, blue: 36/255, opacity: 0.97)

    static let monoURLFont = Font.system(size: 11.5, design: .monospaced)     // github.com/login/device
    static let primaryButtonFont = Font.system(size: 12.5, weight: .semibold) // Open GitHub / Sign in
    static let footnoteFont = Font.system(size: 10.5)                         // Keychain note

    /// Both cards: what the sign-in asks for, and why.
    static let scopesNote = "Requests repo + read:org (needed to approve and merge). Token stays in your Keychain."

    static let crossfade = Animation.easeOut(duration: 0.15)
}

// MARK: - Onboarding root

struct OnboardingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            // Without an OAuth client ID (a downloaded release) there's no
            // code to show: token entry is the only way in.
            if state.tokenEntryActive || !state.supportsDeviceFlow {
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
            case .signedIn:
                EmptyView() // PanelRootView won't show onboarding then.
            }
            }
        }
        .padding(OB.cardPadding)
        .frame(width: OB.cardWidth)
        .background(OB.cardBackground)
        .environment(\.colorScheme, .dark) // spec 1e: onboarding is always dark
        .animation(OB.crossfade, value: state.tokenEntryActive)
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

            Text(OB.scopesNote)
                .font(OB.footnoteFont)
                .foregroundStyle(Color.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            // Sign-in failures surface here with a retry — otherwise the card
            // sits on the placeholder code with no explanation. "Session
            // expired" only says why the card is back; a new code is already
            // on its way, so there's nothing to retry.
            if let error = state.inlineError {
                VStack(spacing: 6) {
                    Text(error)
                        .font(OB.footnoteFont)
                        .foregroundStyle(Color(hex: 0xFF7369))
                        .multilineTextAlignment(.center)
                    if info == nil, error != AppState.sessionExpiredMessage {
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

            Text("Create a classic token, then paste it below.")
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

            VStack(spacing: 4) {
                Text(OB.scopesNote)
                // SAML orgs hide their items until the token is authorized.
                Text("Org uses SSO? On the token page: Configure SSO → Authorize.")
            }
            .font(OB.footnoteFont)
            .foregroundStyle(Color.white.opacity(0.35))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)

            if state.supportsDeviceFlow {
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
