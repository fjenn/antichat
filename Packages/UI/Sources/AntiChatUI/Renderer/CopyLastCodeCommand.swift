// ⌘⇧; copies the last code block of the visible chat (M1.T09 step 5; R-008 AC3). The shortcut is a
// `KeyboardShortcuts.Name("copyLastCode")` so Settings → Keyboard shortcuts (M1.T24, AT-103) can rebind it; the menu
// item takes the current binding through `globalKeyboardShortcut` (an in-app key equivalent, never a system hotkey).
// The visible conversation publishes what to copy as a focused-scene value.
import AntiChatDesign
import AppKit
import KeyboardShortcuts
import SwiftUI

public extension FocusedValues {
    /// The visible chat's last code block (nil = none), published by ConversationView.
    @Entry var lastCodeBlock: LastCodeBlockSource?
}

/// What the visible chat would copy: read only when the command fires (no per-token work while a reply streams).
/// Equal by `id` (the chat), so neither streaming deltas nor a send republish the focused value.
public struct LastCodeBlockSource: Equatable {
    let id: String
    let texts: @MainActor () -> [String]

    public init(id: String, texts: @escaping @MainActor () -> [String]) {
        self.id = id
        self.texts = texts
    }

    /// For tests and fixed lists.
    public init(messages: [String]) { self.init(id: messages.joined(separator: "\u{1}"), texts: { messages }) }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// The last code block of the most recent assistant message that has one.
    @MainActor public func code() -> String? {
        for text in texts().reversed() where text.contains("```") || text.contains("~~~") || text.contains("    ") {
            if let c = MarkdownBlocks.lastCodeBlock(in: text) { return c }
        }
        return nil
    }
}

public enum CopyLastCode {
    /// Puts `source`'s last code block on the general pasteboard; false when the chat has none.
    @MainActor @discardableResult
    public static func perform(_ source: LastCodeBlockSource?, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let code = source?.code() else {
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        return true
    }
}

/// Edit › Copy Last Code Block (⌘⇧; by default). Added to the app's commands by `AppCommands` (M1.T24).
public struct CopyLastCodeCommands: Commands {
    @FocusedValue(\.lastCodeBlock) private var source

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button { CopyLastCode.perform(source) } label: { Text(CopyKey("menu.edit.copyLastCode")) }
                .accessibilityIdentifier("menu.edit.copyLastCode")
                .menuShortcut(.copyLastCode)
                .disabled(source == nil)
        }
    }
}

extension View {
    /// Publishes the assistant replies of the visible chat for ⌘⇧; (ConversationView).
    /// NFR-U2: the value is the chat only. It reads the replies when the command fires, so it never needs republishing
    /// while the chat is shown; an id with the message count and the turn state changed on every send, and a new focused
    /// value rebuilds the app's main menu (`AppKitMainMenuItem.updateMainMenu`) in the send's ack frame.
    func lastCodeBlockSource(_ model: ConversationModel) -> some View {
        focusedSceneValue(\.lastCodeBlock, LastCodeBlockSource(id: model.chatID) { [weak model] in
            model?.assistantTexts() ?? []
        })
    }
}
