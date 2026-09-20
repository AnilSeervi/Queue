import AppKit
import SwiftUI

/// Dev tool: QUEUE_SNAPSHOT=<dir> renders every surface to PNGs offscreen and
/// exits. No screen-recording permission needed (draws the app's own views).
@MainActor
enum Snapshotter {
    static func runIfRequested(state: AppState) -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["QUEUE_SNAPSHOT"] else { return false }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Give the initial demo refresh a beat to land, then render everything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // activeTab persists on every assignment; restore the user's last
            // tab afterwards so a snapshot run doesn't clobber it.
            let savedTab = state.activeTab
            for dark in [true, false] {
                let suffix = dark ? "dark" : "light"
                for tab in PanelTab.allCases {
                    state.activeTab = tab
                    snap(PanelRootView().environmentObject(state), dark: dark,
                         to: url.appendingPathComponent("panel-\(tab.rawValue)-\(suffix).png"))
                }
                snap(SettingsView(state: state).environmentObject(state), dark: dark,
                     to: url.appendingPathComponent("settings-\(suffix).png"))
            }
            state.activeTab = savedTab

            // Onboarding (always dark) — both steps, driven by auth state.
            let savedAuth = state.auth
            state.auth = .deviceFlow(DeviceFlowInfo(
                userCode: "7F3A-D21B",
                verificationURL: URL(string: "https://github.com/login/device")!))
            snap(PanelRootView().environmentObject(state), dark: true,
                 to: url.appendingPathComponent("onboarding-step1.png"))
            state.auth = .pickingRepos(MockData.watchableRepos)
            snap(PanelRootView().environmentObject(state), dark: true,
                 to: url.appendingPathComponent("onboarding-step2.png"))
            state.auth = savedAuth

            // Menu bar icon states (both appearances).
            snapIconStates(to: url)

            NSApp.terminate(nil)
        }
        return true
    }

    private static func snap(_ view: some View, dark: Bool, to fileURL: URL) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: fileURL)
        }
        window.orderOut(nil)
    }

    private static func snapIconStates(to dir: URL) {
        let states: [(String, StatusIconState)] = [
            ("all-clear", .allClear),
            ("count", .needsYouCount(4)),
            ("dot", .needsYouDot),
            ("ci-failing", .ciFailing),
            ("snoozed", .snoozed),
        ]
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            for (name, iconState) in states {
                let image = StatusItemController.makeIcon(for: iconState, dark: dark)
                // Composite on a menu-bar-ish background so template icons are visible.
                let canvas = NSImage(size: NSSize(width: image.size.width + 12, height: 24))
                canvas.lockFocus()
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: canvas.size).fill()
                let tinted = tintedIfTemplate(image, dark: dark)
                tinted.draw(at: NSPoint(x: 6, y: (24 - image.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                canvas.unlockFocus()
                if let tiff = canvas.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dir.appendingPathComponent("icon-\(name)-\(suffix).png"))
                }
            }
        }
    }

    /// Approximate the menu bar's template tinting for preview PNGs.
    private static func tintedIfTemplate(_ image: NSImage, dark: Bool) -> NSImage {
        guard image.isTemplate else { return image }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        (dark ? NSColor.white : NSColor.black).set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
