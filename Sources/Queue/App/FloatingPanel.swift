import AppKit
import SwiftUI

/// Borderless, non-activating panel that behaves like a popover anchored to
/// the status item: closes when it loses key status or on Esc.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?

    /// The status item button the panel is anchored under.
    private weak var anchorButton: NSStatusBarButton?
    private var resizeObserver: NSObjectProtocol?

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

    override func close() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
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
