import AppKit
import SwiftUI

@main
enum QueueMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var state: AppState!
    private var statusController: StatusItemController!
    private var panel: FloatingPanel?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.make()
        self.state = state

        state.openSettingsWindow = { [weak self] in self?.openSettings() }
        state.closePanel = { [weak self] in self?.closePanel() }

        statusController = StatusItemController(state: state) { [weak self] in
            self?.togglePanel()
        }
        state.onStateChange = { [weak self] in self?.statusController.render() }

        state.startRefreshTimer()
        Task { await state.refresh() }

        hotKey = HotKey { [weak self] in self?.togglePanel() }

        // Dev tool: render all surfaces to PNGs and exit.
        if Snapshotter.runIfRequested(state: state) { return }

        // Testing hook: open the panel immediately (screenshot runs).
        if ProcessInfo.processInfo.environment["QUEUE_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanel()
            }
        }
    }

    // MARK: Panel

    func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = FloatingPanel(rootView: PanelRootView().environmentObject(state))
        panel.onClose = { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.show(relativeTo: statusController.button)
    }

    func closePanel() {
        panel?.close()
        panel = nil
    }

    // MARK: Settings

    func openSettings() {
        closePanel()
        SettingsWindowController.shared.show(state: state)
    }
}
