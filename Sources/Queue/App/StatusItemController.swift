import AppKit
import SwiftUI

/// Owns the NSStatusItem and renders the icon states from spec 1c:
/// all clear · needs-you count · needs-you dot · CI-failing red pulsing dot ·
/// snoozed/DND. Badge counts review requests + mentions + own failing PRs only.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private unowned let state: AppState
    private let onToggle: () -> Void
    // NOTE: the spec's pulsing CI-failing dot is deliberately NOT animated.
    // NSStatusItem contents are rasterized into "replicant" snapshots, so ANY
    // continuous animation (timer redraws and CALayer animations alike) makes
    // AppKit re-snapshot the item on the CPU every frame — measured at ~74%
    // CPU sustained. A static dot carries the same signal at zero cost.
    private var appearanceObservation: NSKeyValueObservation?

    init(state: AppState, onToggle: @escaping () -> Void) {
        self.state = state
        self.onToggle = onToggle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Colored states (.needsYouDot / .ciFailing) bake the glyph color
            // into a non-template image; redraw when the menu bar's appearance
            // flips so the glyph doesn't go invisible until the next poll.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.draw(self.state.statusIconState)
                }
            }
        }
        render()
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Control-click is delivered as a left click with the control modifier —
        // it's the canonical secondary click, so it gets the context menu too.
        let controlClick = event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true
        if event?.type == .rightMouseUp || controlClick {
            showContextMenu()
        } else {
            onToggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { Task { await state.refresh() } }
    @objc private func openSettings() { state.openSettingsWindow?() }

    var button: NSStatusBarButton? { statusItem.button }

    // MARK: Rendering

    func render() {
        draw(state.statusIconState)
    }

    /// Last (state, appearance) actually rendered into the button.
    private var lastDrawn: (state: StatusIconState, dark: Bool)?

    private func draw(_ iconState: StatusIconState) {
        guard let button = statusItem.button else { return }
        let darkMenuBar = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Setting button.image invalidates the view, which makes AppKit
        // re-snapshot the status item (replicants) and re-poke
        // effectiveAppearance — which fires our KVO observer again. Without
        // this guard that feedback loop redraws forever (~75% CPU). Only touch
        // the button when the rendered content would actually differ.
        if let last = lastDrawn, last.state == iconState, last.dark == darkMenuBar { return }
        lastDrawn = (iconState, darkMenuBar)

        button.image = Self.makeIcon(for: iconState, dark: darkMenuBar)
        button.toolTip = "Queue"
    }

    /// Draws the 15px PR glyph (stroke 1.6, round caps) plus state adornments.
    static func makeIcon(for iconState: StatusIconState, dark: Bool, pulseAlpha: CGFloat = 1, includeCIDot: Bool = true) -> NSImage {
        let glyphSize: CGFloat = 15
        let height: CGFloat = 18
        var width: CGFloat = 19

        var countText: String?
        if case .needsYouCount(let n, _) = iconState {
            countText = "\(n)"
            let textWidth = (countText! as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
            ).width
            width += textWidth + 4
        }

        // Colored dots can't live in a template image; those states draw
        // explicitly in the menu bar's resolved appearance.
        let needsColor: Bool
        switch iconState {
        case .needsYouDot, .ciFailing, .needsYouCount(_, ciFailing: true): needsColor = true
        default: needsColor = false
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let mono: NSColor = needsColor ? (dark ? .white : .black) : .black
            let glyphAlpha: CGFloat
            switch iconState {
            case .snoozed: glyphAlpha = 0.35
            case .allClear: glyphAlpha = 0.85
            default: glyphAlpha = 1
            }

            let glyphRect = NSRect(x: 2, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize)
            drawPRGlyph(in: glyphRect, color: mono.withAlphaComponent(glyphAlpha))

            switch iconState {
            case .needsYouCount(_, let ciFailing):
                if ciFailing {
                    let dot = NSBezierPath(ovalIn: NSRect(x: glyphRect.maxX - 3, y: height - 6.5, width: 6, height: 6))
                    NSColor(red: 1, green: 0.37, blue: 0.32, alpha: 1).setFill() // #ff5f52
                    dot.fill()
                }
                if let countText {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: mono,
                    ]
                    let size = (countText as NSString).size(withAttributes: attributes)
                    (countText as NSString).draw(
                        at: NSPoint(x: glyphRect.maxX + 4, y: (height - size.height) / 2),
                        withAttributes: attributes
                    )
                }
            case .needsYouDot:
                let dot = NSBezierPath(ovalIn: NSRect(x: glyphRect.maxX - 3, y: height - 6.5, width: 6, height: 6))
                NSColor(red: 1, green: 0.70, blue: 0.25, alpha: 1).setFill() // #ffb340
                dot.fill()
            case .ciFailing:
                if includeCIDot {
                    let dot = NSBezierPath(ovalIn: NSRect(x: glyphRect.maxX - 3, y: height - 6.5, width: 6, height: 6))
                    NSColor(red: 1, green: 0.37, blue: 0.32, alpha: pulseAlpha).setFill() // #ff5f52
                    dot.fill()
                }
            case .snoozed:
                // Small "z" strokes at top-right.
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                    .foregroundColor: mono.withAlphaComponent(0.5),
                ]
                ("z" as NSString).draw(at: NSPoint(x: glyphRect.maxX - 1, y: glyphRect.maxY - 6), withAttributes: attributes)
            case .allClear:
                break
            }
            return true
        }
        // Template when purely monochrome → macOS tints per appearance.
        image.isTemplate = !needsColor
        return image
    }

    private static func drawPRGlyph(in rect: NSRect, color: NSColor) {
        let s = rect.width / 16
        // NSImage draw block is unflipped: y grows upward; mirror the 16-grid.
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.minY + (16 - y) * s)
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (cx - r) * s, y: rect.minY + (16 - cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }

        color.setStroke()
        let lineWidth = 1.6 * s

        for path in [circle(4.5, 4, 1.9), circle(4.5, 12, 1.9), circle(11.4, 12, 1.9)] {
            path.lineWidth = lineWidth
            path.stroke()
        }

        let line = NSBezierPath()
        line.move(to: pt(4.5, 6.3))
        line.line(to: pt(4.5, 9.7))
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.stroke()

        let arc = NSBezierPath()
        arc.move(to: pt(6.8, 4))
        arc.line(to: pt(9.4, 4))
        arc.curve(to: pt(11.4, 6), controlPoint1: pt(10.9, 4), controlPoint2: pt(11.4, 4.7))
        arc.line(to: pt(11.4, 9.7))
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        arc.lineJoinStyle = .round
        arc.stroke()
    }
}
