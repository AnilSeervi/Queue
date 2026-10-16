import SwiftUI
import AppKit

/// NSVisualEffectView wrapper — native vibrancy behind the panel tint.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Root of the status-item panel. Signed in → tab bar + content + footer;
/// otherwise onboarding cards (spec 1e). An SSO notice, when GitHub sends
/// one, takes a line at the bottom of the content area — it affects every
/// tab — so the panel keeps its size.
struct PanelRootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ds = DS(scheme)
        Group {
            if case .signedIn = state.auth {
                VStack(spacing: 0) {
                    TabBarView()
                    VStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let notice = state.ssoNotice {
                            SSONoticeLine(notice: notice) { state.open($0) }
                        }
                    }
                    .frame(width: DSMetric.panelWidth, height: DSMetric.contentHeight)
                    FooterView()
                }
                .frame(width: DSMetric.panelWidth)
            } else {
                OnboardingView()
            }
        }
        .background {
            ZStack {
                VisualEffectBackground()
                ds.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DSMetric.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSMetric.panelRadius, style: .continuous)
                .stroke(ds.panelBorder, lineWidth: 1)
        )
        // The panel is key when open, so AppKit gives the first control (the
        // Inbox tab) a focus ring — not part of the design; buttons are
        // pointer-driven here.
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch state.activeTab {
        case .inbox: InboxView()
        case .prs: MyPRsView()
        case .issues: IssuesView()
        case .stats: StatsView()
        }
    }
}
