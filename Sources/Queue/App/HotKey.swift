import AppKit
import Carbon.HIToolbox

/// A global shortcut as Carbon registers it: a virtual key code (a physical
/// key position) plus a modifier mask.
struct KeyCombo: Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌥⇧G: toggles the panel.
    static let togglePanel = KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(optionKey | shiftKey))

    /// "⌥⇧G": modifiers in menu order (⌃⌥⇧⌘), then the key as the current
    /// keyboard layout labels it (on Dvorak the G position types "I").
    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keyLabel(keyCode) ?? "key \(keyCode)")
    }

    /// The unmodified character the key types on the current ASCII-capable
    /// layout, uppercased; nil if the layout can't be read.
    private static func keyLabel(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label.uppercased()
    }
}

/// Carbon global hotkey wrapper (no accessibility permission needed).
/// Returns nil when the combination can't be registered (e.g. another app
/// holds it); Settings then shows the shortcut as unavailable.
final class HotKey {
    let combo: KeyCombo
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    init?(_ combo: KeyCombo = .togglePanel, handler: @escaping () -> Void) {
        self.combo = combo
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let instance = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { instance.handler() }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5155_4555) /* "QUEU" */, id: 1)
        let registerStatus = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            // deinit still runs for a failed init; don't remove it twice.
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
