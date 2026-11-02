import AppKit
import SwiftUI

/// The panel's search row (⌘F or typing). A native NSSearchField so the
/// key monitor can tell when it's being typed in, and so it takes the
/// keyboard focus the moment it appears with the caret after what was typed.
struct SearchBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 34

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            NativeSearchField(
                text: Binding(
                    get: { state.searchText[state.activeTab] ?? "" },
                    set: { state.searchText[state.activeTab] = $0 }
                ),
                placeholder: placeholder,
                focusToken: state.searchFocusToken
            )
            .frame(height: 22)
            .padding(.horizontal, 10)
            .frame(height: Self.height - 1)
            Rectangle().fill(ds.hairline).frame(height: 1)
        }
    }

    private var placeholder: String {
        switch state.activeTab {
        case .inbox: return "Search the Inbox — title or #number"
        case .prs: return "Search your PRs — title or #number"
        case .issues: return "Search issues — title or #number"
        case .stats: return "Search"
        }
    }
}

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int

    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .systemFont(ofSize: 12.5)
        context.coordinator.lastToken = focusToken
        return field
    }

    func updateNSView(_ field: FocusingSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            field.takeFocus()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastToken = 0
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Takes the focus as soon as it's in a window, caret at the end.
final class FocusingSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }
    }

    func takeFocus() {
        guard let window else { return }
        window.makeFirstResponder(self)
        // Becoming first responder selects everything; typing would replace it.
        if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
    }

    /// The search field (its field editor) is being typed in.
    static func isEditing(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as AnyObject?) is FocusingSearchField
    }
}
