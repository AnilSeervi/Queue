import AppKit
import SwiftUI

/// Dev tool: QUEUE_SNAPSHOT=<dir> renders every surface to PNGs offscreen and
/// exits. No screen-recording permission needed (draws the app's own views).
/// QUEUE_ICON=<dir> instead writes the app icon as <dir>/Queue.iconset and
/// exits (scripts/make-icon.sh turns that into Resources/Queue.icns).
@MainActor
enum Snapshotter {
    static func runIfRequested(state: AppState) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["QUEUE_ICON"] {
            let iconset = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("Queue.iconset")
            guard writeIconSet(to: iconset) else {
                FileHandle.standardError.write(Data("Queue: could not write \(iconset.path)\n".utf8))
                exit(1)
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        }
        guard let dir = env["QUEUE_SNAPSHOT"] else { return false }
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
                // The Done sections opened, scrolled to the end.
                state.expandedDone = [.inbox, .prs]
                for tab in [PanelTab.inbox, .prs] {
                    state.activeTab = tab
                    snap(PanelRootView().environmentObject(state).environment(\.listScrollAnchor, .bottom),
                         dark: dark, to: url.appendingPathComponent("panel-\(tab.rawValue)-done-\(suffix).png"))
                }
                state.expandedDone = []
                // Hover actions, as if the pointer were on the rows.
                for (name, tab, preview) in hoverPreviews {
                    state.activeTab = tab
                    // The stack's merge confirm sits at the end of My PRs.
                    let anchor: UnitPoint? = name == "prs-merge" ? .bottom : nil
                    snap(PanelRootView().environmentObject(state).environment(\.rowPreview, preview)
                            .environment(\.listScrollAnchor, anchor),
                         dark: dark, to: url.appendingPathComponent("panel-\(name)-\(suffix).png"))
                }
                snap(SettingsView(state: state).environmentObject(state), dark: dark,
                     to: url.appendingPathComponent("settings-\(suffix).png"))
            }
            state.activeTab = savedTab

            // Onboarding (always dark) — device code, then token entry.
            let savedAuth = state.auth
            state.auth = .deviceFlow(DeviceFlowInfo(
                userCode: "7F3A-D21B",
                verificationURL: URL(string: "https://github.com/login/device")!))
            snap(PanelRootView().environmentObject(state), dark: true,
                 to: url.appendingPathComponent("onboarding-step1.png"))
            state.tokenEntryActive = true
            snap(PanelRootView().environmentObject(state), dark: true,
                 to: url.appendingPathComponent("onboarding-token.png"))
            state.tokenEntryActive = false
            state.auth = savedAuth

            // Menu bar icon states (both appearances), plus the app icon.
            snapIconStates(to: url)
            if let icon = appIcon(pixels: 1024) {
                writePNG(NSBitmapImageRep(cgImage: icon), to: url.appendingPathComponent("app-icon.png"))
            }

            NSApp.terminate(nil)
        }
        return true
    }

    /// Inbox: a review request's icons and a mention's, with the fork PR's
    /// branch opening in the editor. My PRs: a failing PR's icons (Re-run)
    /// and a ready one's (Merge), then that Merge asking to confirm.
    private static var hoverPreviews: [(name: String, tab: PanelTab, preview: RowPreview)] {
        var opening: Set<String> = []
        for case .review(let request) in MockData.inbox where request.branchRef?.isFromFork == true {
            if let ref = request.branchRef { opening.insert(AppState.editorKey(ref)) }
        }
        return [
            ("inbox-hover", .inbox, RowPreview(hovered: ["rr-4821", "m-4790"], busy: opening)),
            ("prs-hover", .prs, RowPreview(hovered: ["pr-391", "pr-2215"])),
            ("prs-merge", .prs, RowPreview(hovered: ["pr-2231"], confirmingMerge: ["pr-2231"])),
        ]
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
            ("count", .needsYouCount(4, ciFailing: false)),
            ("count-ci", .needsYouCount(4, ciFailing: true)),
            ("dot", .needsYouDot),
            ("ci-failing", .ciFailing),
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

    // MARK: App icon

    /// Every file `iconutil -c icns` expects: (name, pixels, points).
    private static let iconSetSizes: [(String, Int, Int)] = [16, 32, 128, 256, 512].flatMap { pt in
        [("icon_\(pt)x\(pt).png", pt, pt), ("icon_\(pt)x\(pt)@2x.png", pt * 2, pt)]
    }

    private static func writeIconSet(to dir: URL) -> Bool {
        try? FileManager.default.removeItem(at: dir)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return false }
        for (name, pixels, points) in iconSetSizes {
            guard let image = appIcon(pixels: pixels) else { return false }
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: points, height: points) // 72 dpi at 1x, 144 at @2x
            guard writePNG(rep, to: dir.appendingPathComponent(name)) else { return false }
        }
        return true
    }

    @discardableResult
    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// The Dock/Finder icon: the menu-bar PR glyph in white on the dark panel
    /// color, with the amber "needs you" dot. Shape and margins follow Apple's
    /// macOS grid: an 824pt continuous-corner squircle centered in a 1024pt
    /// canvas, its drop shadow in the margin.
    static func appIcon(pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Everything below is in the 1024pt design space. Shadow offsets and
        // blurs ignore the CTM, so those scale by k explicitly.
        let k = CGFloat(pixels) / 1024
        ctx.scaleBy(x: k, y: k)

        let ds = DS(.dark)
        let base = NSColor(ds.panelTint).withAlphaComponent(1)
        let amber = NSColor(ds.attention)
        func mix(_ color: NSColor, _ other: NSColor, _ fraction: CGFloat) -> CGColor {
            guard let a = color.usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB),
                  let mixed = a.blended(withFraction: fraction, of: b) else { return color.cgColor }
            return mixed.cgColor
        }
        func white(_ alpha: CGFloat) -> CGColor { NSColor(white: 1, alpha: alpha).cgColor }
        func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        }

        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
        let top = CGPoint(x: body.midX, y: body.maxY), bottom = CGPoint(x: body.midX, y: body.minY)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(base.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Body: the panel color lit from above, a soft glow at the top, and a
        // thin rim that catches the light along the top edge.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let fill = gradient([mix(base, .white, 0.12), base.cgColor, mix(base, .black, 0.4)], [0, 0.55, 1]) {
            ctx.drawLinearGradient(fill, start: top, end: bottom, options: [])
        }
        if let glow = gradient([white(0.10), white(0)], [0, 1]) {
            let center = CGPoint(x: body.midX, y: 930)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: 620, options: [])
        }
        ctx.addPath(shape)
        ctx.setLineWidth(6) // half of it falls inside the clip: a 3pt rim
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let rim = gradient([white(0.28), white(0.04), white(0.02)], [0, 0.5, 1]) {
            ctx.drawLinearGradient(rim, start: top, end: bottom, options: [])
        }
        ctx.restoreGState()

        // Glyph, drawn larger at the tiny sizes so its strokes survive, and
        // nudged left/up so glyph + dot read as centered.
        let side: CGFloat = pixels <= 32 ? 600 : 500
        let glyph = NSRect(x: 512 - side * 0.522, y: 512 - side * 0.488, width: side, height: side)
        let s = side / 16 // the glyph's 16-unit grid

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 22 * k,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        StatusItemController.drawPRGlyph(in: glyph, color: .white)
        // Shade the strokes white → light gray, top to bottom.
        ctx.setBlendMode(.sourceAtop)
        if let shade = gradient([white(1), mix(.white, base, 0.15)], [0, 1]) {
            ctx.drawLinearGradient(shade, start: CGPoint(x: glyph.midX, y: glyph.maxY),
                                   end: CGPoint(x: glyph.midX, y: glyph.minY), options: [])
        }
        ctx.setBlendMode(.normal)
        // Amber dot off the glyph's top-right, where the menu bar draws it.
        let dot = CGRect(x: glyph.minX + (13.9 - 1.55) * s, y: glyph.minY + (16 - 2.3 - 1.55) * s,
                         width: 3.1 * s, height: 3.1 * s)
        ctx.saveGState()
        ctx.addEllipse(in: dot)
        ctx.clip()
        if let fill = gradient([mix(amber, .white, 0.2), amber.cgColor, mix(amber, .black, 0.08)], [0, 0.5, 1]) {
            ctx.drawLinearGradient(fill, start: CGPoint(x: dot.midX, y: dot.maxY),
                                   end: CGPoint(x: dot.midX, y: dot.minY), options: [])
        }
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }
}
