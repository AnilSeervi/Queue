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
    /// fields (the token field) unless a main menu declares them. The menu
    /// is never visible; it carries the standard key equivalents: ⌘, opens
    /// Settings, ⌘W closes Settings or the panel, ⌘M minimizes Settings.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z") // ⇧⌘Z
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) { openSettings() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let state = AppState.make()
        self.state = state

        state.openSettingsWindow = { [weak self] in self?.openSettings() }
        state.closePanel = { [weak self] in self?.closePanel() }
        Notifier.shared.openPanel = { [weak self] in self?.showPanel() }
        Notifier.shared.onMentionOpened = { [weak state] threadID, updatedAt, done in
            state?.markThreadRead(threadID, updatedAt: updatedAt, done: done)
        }

        statusController = StatusItemController(
            state: state,
            onToggle: { [weak self] in self?.togglePanel() },
            onOpenPanel: { [weak self] in self?.showPanel() }
        )
        state.onStateChange = { [weak self] in
            self?.statusController.render()
            self?.askForNotificationsOnceLoaded()
        }

        // The one launch refresh (live and demo); later ones come from the
        // timer, panel opens, wake and the user.
        state.startRefreshTimer()
        Task { await state.refresh() }
        state.observeSystemWake()

        hotKey = HotKey(.togglePanel) { [weak self] in self?.togglePanel() }
        SettingsWindowController.shared.globalShortcut = (.togglePanel, registered: hotKey != nil)

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

    /// One panel at a time: a notification click or the hotkey while it's
    /// open brings the existing one forward instead of stacking a second.
    func showPanel() {
        state.refreshIfStale()
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = FloatingPanel(rootView: PanelRootView().environmentObject(state))
        // A late onClose from an older panel must not drop this one.
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.panel === panel else { return }
            self.panel = nil
        }
        self.panel = panel
        panel.show(relativeTo: statusController.button)
    }

    func closePanel() {
        panel?.close()
        panel = nil
    }

    // MARK: Notifications

    private var askedForNotifications = false

    /// The permission prompt waits for the first refresh that loaded:
    /// there's something to announce by then, and it doesn't land on top of
    /// the sign-in card.
    private func askForNotificationsOnceLoaded() {
        guard !askedForNotifications, !AppState.isDemo, state.hasLoaded else { return }
        askedForNotifications = true
        Notifier.shared.requestPermissionIfNeeded()
    }

    // MARK: Settings

    func openSettings() {
        closePanel()
        SettingsWindowController.shared.show(state: state)
    }
}
