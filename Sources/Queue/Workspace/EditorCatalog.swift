import AppKit

// The editors "open in editor" can use, found through LaunchServices by
// bundle id (wherever they're installed). Settings lists the installed ones;
// with none chosen, the first installed in `known` order is used — Xcode
// last, since it's often installed for its toolchain rather than as an
// editor.

struct Editor: Hashable, Sendable {
    var name: String
    /// Release first; later ones are older versions or other channels.
    var bundleIDs: [String]
}

struct InstalledEditor: Hashable, Identifiable, Sendable {
    var name: String
    /// The id that's installed (what SettingsStore.editorBundleID stores).
    var bundleID: String
    var appURL: URL

    var id: String { bundleID }
}

@MainActor
enum EditorCatalog {
    static let known: [Editor] = [
        Editor(name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"]),
        Editor(name: "Visual Studio Code - Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"]),
        Editor(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        Editor(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"]),
        Editor(name: "VSCodium", bundleIDs: ["com.vscodium"]),
        Editor(name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        Editor(name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"]),
        Editor(name: "Nova", bundleIDs: ["com.panic.Nova"]),
        Editor(name: "BBEdit", bundleIDs: ["com.barebones.bbedit"]),
        Editor(name: "TextMate", bundleIDs: ["com.macromates.TextMate", "com.macromates.TextMate.preview"]),
        Editor(name: "IntelliJ IDEA", bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        Editor(name: "WebStorm", bundleIDs: ["com.jetbrains.WebStorm"]),
        Editor(name: "PyCharm", bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        Editor(name: "GoLand", bundleIDs: ["com.jetbrains.goland"]),
        Editor(name: "PhpStorm", bundleIDs: ["com.jetbrains.PhpStorm"]),
        Editor(name: "RubyMine", bundleIDs: ["com.jetbrains.rubymine"]),
        Editor(name: "CLion", bundleIDs: ["com.jetbrains.CLion"]),
        Editor(name: "Rider", bundleIDs: ["com.jetbrains.rider"]),
        Editor(name: "RustRover", bundleIDs: ["com.jetbrains.rustrover"]),
        Editor(name: "DataGrip", bundleIDs: ["com.jetbrains.datagrip"]),
        Editor(name: "Android Studio", bundleIDs: ["com.google.android.studio"]),
        Editor(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]),
    ]

    /// The known editors that are installed, in `known` order.
    static func installed() -> [InstalledEditor] {
        known.compactMap { editor in
            for bundleID in editor.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return InstalledEditor(name: editor.name, bundleID: bundleID, appURL: url)
                }
            }
            return nil
        }
    }

    /// The editor to open in: `bundleID` (the setting) when it's installed,
    /// else the first installed one; nil when there's none.
    static func preferred(_ bundleID: String?) -> InstalledEditor? {
        let editors = installed()
        if let bundleID {
            if let chosen = editors.first(where: { $0.bundleID == bundleID }) { return chosen }
            // Another channel of the same editor (Sublime Text 3 → 4).
            if let family = known.first(where: { $0.bundleIDs.contains(bundleID) }),
               let sibling = editors.first(where: { family.bundleIDs.contains($0.bundleID) }) {
                return sibling
            }
        }
        return editors.first
    }

    static func icon(for editor: InstalledEditor) -> NSImage {
        NSWorkspace.shared.icon(forFile: editor.appURL.path)
    }

    /// Opens `folder` in `editor` and brings it to the front.
    static func open(_ folder: URL, in editor: InstalledEditor) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([folder], withApplicationAt: editor.appURL, configuration: configuration)
        } catch {
            throw WorkspaceError.editorFailed("\(editor.name) couldn't open \(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
