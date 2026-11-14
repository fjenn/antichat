// TriggerDetectorTests (M1.T17; AT-013 leg 2 unit part): `/` only at the input start, `@` at any word start, the
// query up to the caret, whitespace ends it, IME composition never triggers; the inline menu's filter, wrap-around
// navigation, Esc and picks over the same list as +.
import Foundation
import Testing
@testable import AntiChatHarness
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct TriggerDetectorTests {
    private func detect(_ s: String, caret: Int? = nil) -> ComposerTrigger? {
        TriggerDetector.detect(text: s, caret: caret ?? (s as NSString).length)
    }

    @Test func slashOnlyAtTheInputStart() {
        #expect(detect("/") == ComposerTrigger(key: .slash, location: 0, query: ""))
        #expect(detect("/web") == ComposerTrigger(key: .slash, location: 0, query: "web"))
        #expect(detect("hello /web") == nil, "/ mid-text does not open the menu")
        #expect(detect("a/b") == nil)
        #expect(detect("line\n/web") == nil, "a later line is not the input start")
        #expect(detect(" /web") == nil)
    }

    @Test func atAnywhereAWordStarts() {
        #expect(detect("@") == ComposerTrigger(key: .at, location: 0, query: ""))
        #expect(detect("look this up @web") == ComposerTrigger(key: .at, location: 13, query: "web"))
        #expect(detect("line\n@ec") == ComposerTrigger(key: .at, location: 5, query: "ec"))
        #expect(detect("mail me at a@b.com") == nil, "an e-mail address is not a trigger")
    }

    @Test func queryEndsAtWhitespaceAndCaret() {
        #expect(detect("@web search") == nil, "a space closes the menu")
        #expect(detect("@web more", caret: 4) == ComposerTrigger(key: .at, location: 0, query: "web"))
        #expect(detect("@web", caret: 0) == nil)
        #expect(TriggerDetector.detect(text: "@we", caret: 3, hasMarkedText: true) == nil, "IME composing")
    }

    @Test func removingTheTriggerLeavesTheRest() {
        let t = detect("ask @web", caret: 8)!
        #expect(t.range == NSRange(location: 4, length: 4))
        #expect(TriggerDetector.removing(t, from: "ask @web").text == "ask ")
        let s = detect("/ima")!
        #expect(TriggerDetector.removing(s, from: "/ima").text == "")
        let mid = TriggerDetector.detect(text: "a @x b", caret: 4)!
        #expect(TriggerDetector.removing(mid, from: "a @x b") == ("a b", 2), "the doubled space collapses")
    }

    // MARK: Inline menu over the same list as +

    private func menus(_ c: ComposerMenuContext) -> (ComposerModel, ComposerMenus) {
        let m = ComposerModel()
        m.menus.context = c
        return (m, m.menus)
    }

    private static let full = ComposerMenuContext(
        installedPacks: ["chat", "photo", "video"], webSearchEnabled: true, connectionsEnabled: true,
        activeModelKey: "chat-9b-q4",
        tools: [.init(name: "echo", description: "Repeat the given text back."),
                .init(name: "write_note", description: "Save a short note for the user.")])

    @Test func slashAndAtOpenTheSameListAndTypingFilters() {
        let (m, x) = menus(Self.full)
        m.text = "/"
        x.update(text: m.text, caret: 1)
        #expect(x.isInlineOpen)
        let slashList = x.inlineItems.map(\.id)
        m.text = "hi @"
        x.update(text: m.text, caret: 4)
        #expect(x.inlineItems.map(\.id) == slashList, "/ and @ list the same items")
        #expect(slashList.starts(with: x.addItems.map(\.id)), "the + entries come first")
        #expect(slashList.contains("tool:echo"))
        m.text = "hi @ech"
        x.update(text: m.text, caret: 7)
        #expect(x.inlineItems.first?.id == "tool:echo", "typing filters (fuzzy)")
        m.text = "hi @zzzq"
        x.update(text: m.text, caret: 8)
        #expect(x.inlineItems.isEmpty, "No matches")
        #expect(!x.handleKey(.pick), "Return with no match falls through to send")
    }

    @Test func arrowsWrapAround() {
        let (m, x) = menus(Self.full)
        m.text = "/"
        x.update(text: m.text, caret: 1)
        let n = x.inlineItems.count
        #expect(n > 2)
        #expect(x.selection == 0)
        #expect(x.handleKey(.up))
        #expect(x.selection == n - 1, "↑ from the first goes to the last")
        #expect(x.handleKey(.down))
        #expect(x.selection == 0, "↓ from the last goes to the first")
    }

    @Test func escClosesUntilTheTriggerIsTypedAgain() {
        let (m, x) = menus(Self.full)
        m.text = "@we"
        x.update(text: m.text, caret: 3)
        #expect(x.handleKey(.escape))
        #expect(!x.isInlineOpen)
        x.update(text: "@web", caret: 4)
        #expect(!x.isInlineOpen, "still the same trigger")
        x.update(text: "@web ", caret: 5)
        x.update(text: "@web @", caret: 6)
        #expect(x.isInlineOpen, "a new trigger opens it again")
    }

    @Test func pickingAToolRemovesTheTriggerAndAddsAChip() {
        let (m, x) = menus(Self.full)
        m.text = "please @ech"
        x.update(text: m.text, caret: 11)
        #expect(x.handleKey(.pick))
        #expect(m.text == "please ")
        #expect(x.chips.chips.map(\.id) == ["tool:echo"])
        #expect(!x.isInlineOpen)
    }

    @Test func pathQueryBrowsesFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t17-at-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let (m, x) = menus(Self.full)
        m.text = "@" + dir.path + "/"
        x.update(text: m.text, caret: (m.text as NSString).length)
        #expect(x.isPathMode)
        for _ in 0..<200 where x.fileItems.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(x.fileItems.map(\.name) == ["Sub", "note.txt"], "folders first")
        x.move(1)
        #expect(x.handleKey(.pick))
        #expect(m.attachments.first?.fileURL?.lastPathComponent == "note.txt")
        #expect(m.text.isEmpty)
        #expect(ComposerMenus.completedPath(query: "~/Doc", name: "Documents") == "~/Documents/")
        #expect(ComposerMenus.completedPath(query: "/", name: "tmp") == "/tmp/")
        #expect(ComposerMenus.completedPath(query: "~", name: "x") == "~/x/")
    }
}
