// Edit menu pasteboard group (M1.T24 step 2; R-103 "⌘A selects only the conversation text"). The standard items,
// sent to the key window's first responder as AppKit's own items are, except two that know the transcript:
// - Select All ⌘A: with a text view or field focused (the composer, the find field, a rename field) it selects
//   that text as usual; otherwise it selects the conversation only (`TranscriptSelection`), never the sidebar,
//   composer or window chrome.
// - Copy ⌘C: after that transcript selection (and no text view focused) it copies exactly the transcript text.
import AntiChatDesign
import AppKit
import SwiftUI

@MainActor
enum EditRouting {
    /// The key window's first responder is editable or selectable text (it owns ⌘A / ⌘C itself).
    static var textHasFocus: Bool { keyWindow()?.firstResponder is NSText }

    /// The key window (tests stand in a window here: a background test run never has a key window, BackgroundRun).
    static var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }

    static func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    /// The conversation ⌘A / ⌘C act on: the target window's visible chat (nil outside a main window).
    static func conversation(_ state: WindowState?) -> ConversationModel? {
        guard let state, keyWindow() == nil || keyWindow() === state.window else { return nil }
        return state.conversation?()
    }

    /// ⌘A. Returns what it did (probe/tests).
    @discardableResult
    static func selectAll(_ state: WindowState?) -> Bool {
        if !textHasFocus, let conv = conversation(state), !conv.messages.isEmpty {
            conv.selection.selectAll()
            return true
        }
        send(#selector(NSResponder.selectAll(_:)))
        return false
    }

    /// ⌘C. Returns true when it copied the transcript selection.
    @discardableResult
    static func copy(_ state: WindowState?, to pasteboard: NSPasteboard = .general) -> Bool {
        if !textHasFocus, let conv = conversation(state), conv.selection.isAll {
            MessageCopier.copy(plain: conv.transcriptText(), to: pasteboard)
            return true
        }
        send(#selector(NSText.copy(_:)))
        return false
    }
}

struct EditCommands: Commands {
    @FocusedValue(\.windowState) private var focused
    private var state: WindowState? { MenuTarget.state(focused) }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button { EditRouting.send(#selector(NSText.cut(_:))) } label: { Text(CopyKey("menu.edit.cut")) }
                .accessibilityIdentifier("menu.edit.cut")
                .keyboardShortcut("x")
            Button { EditRouting.copy(state) } label: { Text(CopyKey("menu.edit.copy")) }
                .accessibilityIdentifier("menu.edit.copy")
                .keyboardShortcut("c")
            Button { EditRouting.send(#selector(NSText.paste(_:))) } label: { Text(CopyKey("menu.edit.paste")) }
                .accessibilityIdentifier("menu.edit.paste")
                .keyboardShortcut("v")
            Button { EditRouting.send(#selector(NSTextView.pasteAsPlainText(_:))) } label: { Text(CopyKey("menu.edit.pasteMatch")) }
                .accessibilityIdentifier("menu.edit.pasteMatch")
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            // No plain "Delete" item: SwiftUI handed it the chat item's ⇧⌘⌫ (both ended up with the ⌫ key
            // equivalent and the first one, `delete:`, took the key), so Delete Chat… never ran. ⌫ in text is the key.
            Button { EditRouting.selectAll(state) } label: { Text(CopyKey("menu.edit.selectAll")) }
                .accessibilityIdentifier("menu.edit.selectAll")
                .keyboardShortcut("a")
        }
    }
}
