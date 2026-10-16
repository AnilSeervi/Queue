import AppKit
import SwiftUI

/// Owns the NSStatusItem and renders the icon states from spec 1c:
/// all clear · needs-you count · needs-you dot · CI-failing red pulsing dot ·
/// loading. Badge counts review requests + mentions + your PRs
/// that need you (failing CI, changes requested, conflicts) only. The icon's
/// meaning is also spelled out as its tooltip and VoiceOver label.
///
/// Right-click (or control-click) opens a menu listing what needs you,
/// oldest first, above the app commands.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private unowned let state: AppState
    private let onToggle: () -> Void
    private let onOpenPanel: () -> Void
    // NOTE: the spec's pulsing CI-failing dot is deliberately NOT animated.
    // NSStatusItem contents are rasterized into "replicant" snapshots, so ANY
    // continuous animation (timer redraws and CALayer animations alike) makes
    // AppKit re-snapshot the item on the CPU every frame — measured at ~74%
    // CPU sustained. A static dot carries the same signal at zero cost.
    private var appearanceObservation: NSKeyValueObservation?

    init(state: AppState, onToggle: @escaping () -> Void, onOpenPanel: @escaping () -> Void) {
        self.state = state
        self.onToggle = onToggle
        self.onOpenPanel = onOpenPanel
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
                Task { @MainActor in self?.render() }
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

    var button: NSStatusBarButton? { statusItem.button }

    // MARK: Context menu

    /// Needs-you rows listed before "…and N more".
    private static let menuItemLimit = 8
    private static let menuTitleLength = 48

    private func showContextMenu() {
        statusItem.menu = makeContextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Built fresh on every right-click, from the current state.
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = NSMenuItem(title: Self.versionTitle, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())

        addNeedsYouItems(to: menu)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open Queue", action: #selector(openPanel), keyEquivalent: "").target = self
        let refresh = menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        if case .signedIn = state.auth {
            refresh.isEnabled = !state.isRefreshing
        } else {
            refresh.isEnabled = false
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// "Queue 0.3.0"; an unbundled dev build has no version keys.
    private static var versionTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Queue \($0)" } ?? "Queue (development build)"
    }

    /// Review requests, direct mentions and your PRs that need you, oldest
    /// first. "…and N more" covers rows past the limit; thread activity that
    /// isn't a direct mention gets one "N threads with new activity" line.
    /// Together they add up to the badge. Both open the panel.
    private func addNeedsYouItems(to menu: NSMenu) {
        guard case .signedIn = state.auth else {
            menu.addItem(Self.note("Not signed in"))
            return
        }
        guard state.hasLoaded else {
            menu.addItem(Self.note(state.inlineError == nil ? "Loading…" : "Couldn't load from GitHub"))
            return
        }
        let entries = needsYouEntries()
        let shown = entries.prefix(Self.menuItemLimit)
        let overflow = entries.count - shown.count
        let activity = state.inbox.filter { entry in
            if case .mention(let mention) = entry { return !mention.isDirect }
            return false
        }.count
        if shown.isEmpty && activity == 0 {
            menu.addItem(Self.note("Nothing needs you ✓"))
            return
        }
        for entry in shown {
            menu.addItem(menuItem(for: entry))
        }
        if overflow > 0 {
            let more = menu.addItem(withTitle: "…and \(overflow) more", action: #selector(openPanel), keyEquivalent: "")
            more.target = self
        }
        if activity > 0 {
            let title = "\(activity) thread\(activity == 1 ? "" : "s") with new activity"
            menu.addItem(withTitle: title, action: #selector(openPanel), keyEquivalent: "").target = self
        }
    }

    /// One needs-you row: what it is, where, and how old.
    private struct NeedsYouEntry {
        var title: String
        /// "api #412 · review requested · 2d"
        var detail: String
        var symbol: String
        /// nil = template (follows the menu's text color).
        var tint: NSColor?
        var date: Date
        var url: URL
        /// Opening a mention also marks its thread read.
        var mention: Mention?
    }

    private func needsYouEntries() -> [NeedsYouEntry] {
        func detail(_ repo: RepoRef, _ number: Int?, _ why: String, _ age: Age) -> String {
            let ref = number.map { "\(repo.name) #\($0)" } ?? repo.name
            return "\(ref) · \(why) · \(age.display)"
        }
        var entries: [NeedsYouEntry] = []
        for entry in state.inbox {
            switch entry {
            case .review(let r):
                entries.append(NeedsYouEntry(
                    title: r.title, detail: detail(r.repo, r.number, "review requested", r.age),
                    symbol: "eye", date: r.age.date, url: r.url))
            case .mention(let m) where m.isDirect:
                let who = m.author.map { "\($0.login) \(m.context)" } ?? m.context
                entries.append(NeedsYouEntry(
                    title: m.title, detail: detail(m.repo, m.number, who, m.age),
                    symbol: "at", date: m.age.date, url: m.url, mention: m))
            case .mention:
                break
            }
        }
        for pr in state.prs where pr.needsYou {
            let (symbol, why, tint): (String, String, NSColor?) =
                pr.isFailing ? ("xmark.circle", pr.pillText, .systemRed)
                : pr.changesRequested ? ("exclamationmark.bubble", "changes requested", nil)
                : ("arrow.triangle.merge", "merge conflicts", nil)
            entries.append(NeedsYouEntry(
                title: pr.title, detail: detail(pr.repo, pr.number, why, pr.age),
                symbol: symbol, tint: tint, date: pr.age.date, url: pr.url))
        }
        return entries.sorted { $0.date < $1.date }
    }

    private func menuItem(for entry: NeedsYouEntry) -> NSMenuItem {
        let item = NSMenuItem(title: Self.shortened(entry.title), action: #selector(openEntry(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuTarget(url: entry.url, mention: entry.mention)
        item.toolTip = "\(entry.title)\n\(entry.detail)"
        if #available(macOS 14.4, *) { item.subtitle = entry.detail }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        if let tint = entry.tint {
            item.image = image?.withSymbolConfiguration(config.applying(.init(paletteColors: [tint])))
        } else {
            item.image = image?.withSymbolConfiguration(config)
        }
        return item
    }

    private struct MenuTarget {
        var url: URL
        var mention: Mention?
    }

    private static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One line, at most `menuTitleLength` characters, cut at a word break
    /// when there's one near the end.
    private static func shortened(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard line.count > menuTitleLength else { return line }
        var cut = line.prefix(menuTitleLength - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 12 {
            cut = cut[..<space]
        }
        while let last = cut.last, last.isWhitespace || last.isPunctuation { cut = cut.dropLast() }
        return cut + "…"
    }

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuTarget else { return }
        if let mention = target.mention { state.markRead(mention) }
        state.open(target.url)
    }

    /// After the menu has finished tracking, so the panel can take key.
    @objc private func openPanel() {
        DispatchQueue.main.async { [weak self] in self?.onOpenPanel() }
    }

    @objc private func refreshNow() { Task { await state.refresh() } }
    @objc private func openSettings() { state.openSettingsWindow?() }

    // MARK: Rendering

    func render() {
        draw(state.statusIconState)
        describe()
    }

    /// Last (state, appearance) actually rendered into the button.
    private var lastDrawn: (state: StatusIconState, dark: Bool)?
    private var lastSummary: String?

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
    }

    /// Tooltip + VoiceOver label: the count and dot exist only as pixels.
    /// Tracked apart from the icon, which doesn't change with the count in
    /// dot/off badge modes; set only when the sentence changes.
    private func describe() {
        guard let button = statusItem.button else { return }
        let summary = statusSummary()
        guard summary != lastSummary else { return }
        lastSummary = summary
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    /// "Queue — 4 need you, CI failing on your PR".
    func statusSummary() -> String {
        guard case .signedIn = state.auth else { return "Queue — signed out" }
        guard state.hasLoaded else {
            return state.inlineError == nil ? "Queue — loading" : "Queue — couldn't load from GitHub"
        }
        let count = state.badgeCount
        let failing = state.prs.filter(\.isFailing).count
        var parts = [count == 0 ? "nothing needs you" : "\(count) need\(count == 1 ? "s" : "") you"]
        switch failing {
        case 0: break
        case 1: parts.append("CI failing on your PR")
        default: parts.append("CI failing on \(failing) of your PRs")
        }
        return "Queue — " + parts.joined(separator: ", ")
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
            case .loading: glyphAlpha = 0.35
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
            case .allClear, .loading:
                break
            }
            return true
        }
        // Template when purely monochrome → macOS tints per appearance.
        image.isTemplate = !needsColor
        return image
    }

    static func drawPRGlyph(in rect: NSRect, color: NSColor) {
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
