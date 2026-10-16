import AppKit
import SwiftUI

/// Borderless, non-activating panel that behaves like a popover anchored to
/// the status item: closes when it loses key status, on Esc or ⌘W, and on a
/// click outside the app.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?

    /// The status item button the panel is anchored under.
    private weak var anchorButton: NSStatusBarButton?
    private var resizeObserver: NSObjectProtocol?
    /// Installed only while the panel is open.
    private var outsideClickMonitor: Any?

    init(rootView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // The panel never activates Queue on its own; without this, AppKit
        // skips tooltips for an inactive app — and the row actions are
        // icon-only, so their tooltips are their labels.
        allowsToolTipsWhenApplicationIsInactive = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting

        // SwiftUI delivers preferredContentSize asynchronously, and the window
        // resizes anchored at its top-left corner — re-anchor/re-clamp under
        // the status item whenever the size changes while open (initial sizing,
        // onboarding card 320 → signed-in 440, …).
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isVisible else { return }
                self.repositionUnderAnchor()
            }
        }
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// ⌘W (main menu Close). A borderless window has no close button, so
    /// NSWindow would refuse it.
    override func performClose(_ sender: Any?) {
        close()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(menuItem)
    }

    override func close() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        super.close()
        onClose?()
    }

    /// Position under the status item button, centered on it, clamped to screen.
    func show(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        layoutIfNeeded()
        // The async preferred size usually hasn't landed yet (frame is 0×0);
        // measure the hosted SwiftUI content synchronously so the first
        // placement uses the real panel size.
        if frame.width < 1, let contentView = contentViewController?.view {
            let fitting = contentView.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                setContentSize(fitting)
            }
        }
        repositionUnderAnchor()
        makeKeyAndOrderFront(nil)
        watchForOutsideClicks()
    }

    /// resignKey covers most outside clicks, but clicks that don't move key
    /// focus (the menu bar, another menu bar item, the Dock) leave a
    /// non-activating panel up. A global monitor sees only other apps'
    /// events, so clicks inside Queue (the status item, Settings) don't count.
    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Global monitor handlers run on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.close()
            }
        }
    }

    /// Recompute the origin from the anchor button and the CURRENT size;
    /// called on show and again whenever the content resizes while open.
    private func repositionUnderAnchor() {
        guard
            let button = anchorButton,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else {
            center()
            return
        }
        let buttonFrame = buttonWindow.frame
        let size = frame.size
        var x = buttonFrame.midX - size.width / 2
        let maxX = screen.visibleFrame.maxX - size.width - 8
        x = min(max(x, screen.visibleFrame.minX + 8), maxX)
        let y = buttonFrame.minY - size.height - 6
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
