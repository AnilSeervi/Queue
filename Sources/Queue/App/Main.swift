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

    /// Accessory apps have no menu bar, so ⌘V/⌘C/⌘A/⌘Z never reach text
    /// fields (the token field) unless a main menu declares them.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let state = AppState.make()
        self.state = state

        state.openSettingsWindow = { [weak self] in self?.openSettings() }
        state.closePanel = { [weak self] in self?.closePanel() }
        Notifier.shared.openPanel = { [weak self] in self?.showPanel() }
        if !AppState.isDemo { Notifier.shared.requestPermissionIfNeeded() }

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

    func showPanel() {
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
