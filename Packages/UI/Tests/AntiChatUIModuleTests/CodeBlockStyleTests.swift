// CodeBlockStyleTests (M1.T09 step 3; AT-008 leg 1 and 3): the code block header has the language label, the wrap
// toggle and Copy; Copy puts the code on the pasteboard; > 40 lines collapse behind "Show all"; while streaming only
// completed lines are highlighted and highlighting never changes the block's size; ⌘⇧; is the rebindable
// `copyLastCode` shortcut and copies the last code block of the visible chat; tables copy as CSV.
import AppKit
import KeyboardShortcuts
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct CodeBlockStyleTests {
    static let swift = "let greeting = \"Hello\"\nfunc shout(_ s: String) -> String {\n    s.uppercased()\n}\n"

    @Test func headerShowsLanguageWrapAndCopy() async {
        let h = RendererRig.Host(CodeBlockView(language: "swift", code: Self.swift), look: .light)
        await h.settle()
        #expect(h.frames("codeBlock").count == 1)
        #expect(h.frames("codeLanguage").count == 1)
        #expect(h.frames("codeWrap").count == 1)
        #expect(h.frames("codeCopy").count == 1)
        #expect(h.frames("codeShowAll").isEmpty)
    }

    @Test func copyPutsTheCodeOnThePasteboard() async {
        let h = RendererRig.Host(CodeBlockView(language: "swift", code: Self.swift), look: .light)
        await h.settle()
        #expect(h.click("codeCopy"))
        await h.settle(min: 0.05, stableFor: 0.05)
        #expect(h.pasteboard.string(forType: .string) == String(Self.swift.dropLast()))
    }

    @Test func longBlocksCollapseAfter40Lines() async {
        let forty = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let fortyOne = forty + "\nline 41"
        let a = RendererRig.Host(CodeBlockView(language: "text", code: forty), look: .light)
        await a.settle()
        #expect(a.frames("codeShowAll").isEmpty)
        let b = RendererRig.Host(CodeBlockView(language: "text", code: fortyOne), look: .light)
        await b.settle()
        #expect(b.frames("codeShowAll").count == 1)
        let collapsedHeight = b.host.frame.height
        #expect(b.click("codeShowAll"))
        await b.settle()
        #expect(b.host.frame.height > collapsedHeight)
        #expect(CodeBlockView(language: "text", code: fortyOne).displayed.characters.filter { $0 == "\n" }.count == 39)
    }

    @Test func streamingHighlightsCompletedLinesOnly() async {
        #expect(CodeBlockView.highlightSource("let a = 1\nlet b", streaming: true) == "let a = 1")
        #expect(CodeBlockView.highlightSource("let a", streaming: true) == "")
        #expect(CodeBlockView.highlightSource("let a = 1\nlet b", streaming: false) == "let a = 1\nlet b")
    }

    /// Highlighting only recolours: the block's height is the same before (plain) and after (highlighted).
    @Test func highlightingNeverMovesText() async {
        let code = (1...12).map { "let value\($0) = compute(\($0)) // step \($0)" }.joined(separator: "\n")
        let h = RendererRig.Host(CodeBlockView(language: "swift", code: code), look: .light)
        h.layout()
        let before = h.host.frame.size
        await h.settle(min: 0.6)
        let after = h.host.frame.size
        #expect(abs(after.height - before.height) <= 1)
        let colours = await CodeHighlighter.shared.highlight(code, language: "swift", dark: false)
            .map(CodeHighlighter.colourCount) ?? 0
        #expect(colours > 1)
    }

    @Test func copyLastCodeIsARebindableShortcut() async {
        #expect(KeyboardShortcuts.Name.copyLastCode.rawValue == "copyLastCode")
        let d = KeyboardShortcuts.Name.copyLastCode.initialShortcut
        #expect(d?.key == .semicolon)
        #expect(d?.modifiers == [.command, .shift])
    }

    @Test func copyLastCodeCopiesTheLastBlockOfTheVisibleChat() async {
        let replies = [
            "First:\n```swift\nlet old = 1\n```",
            "Two blocks:\n```python\nprint('a')\n```\nand\n```bash\necho last\n```\nDone.",
            "No code in the newest reply.",
        ]
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("antichat-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(CopyLastCode.perform(LastCodeBlockSource(messages: replies), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "echo last")
        #expect(LastCodeBlockSource(messages: ["plain text only"]).code() == nil)
    }

    @Test func tableCSV() async {
        let md = "| Name | Note |\n|---|---|\n| a, b | say \"hi\" |\n| **c** | `d` |\n\n| X |\n|---|\n| 1 |\n"
        let tables = MarkdownBlocks.tables(in: md)
        #expect(tables.count == 2)
        #expect(MarkdownBlocks.csv(tables[0]) == "Name,Note\r\n\"a, b\",\"say \"\"hi\"\"\"\r\nc,d\r\n")
        #expect(MarkdownBlocks.csv(tables[1]) == "X\r\n1\r\n")
    }

    /// The rendered table's "Copy as CSV" copies that table (the second of two here).
    @Test func tableCopyAsCSVButton() async {
        let md = "| A | B |\n|---|---|\n| 1 | 2 |\n\nBetween.\n\n| C | D |\n|---|---|\n| 3 | 4 |\n"
        let h = RendererRig.Host(MessageMarkdownView(text: md, streaming: false), look: .light)
        await h.settle(min: 1.5)
        print("tableCopyAsCSVButton size", h.host.frame.size, h.frames("markdownTable"), h.frames("codeBlock"))
        let buttons = h.frames("tableCopyCSV").sorted { $0.minY < $1.minY }  // window coords: lower y = lower
        #expect(buttons.count == 2)
        guard let lower = buttons.first else { return }
        let p = CGPoint(x: lower.midX, y: lower.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            h.window.sendEvent(NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        await h.settle(min: 0.05, stableFor: 0.05)
        #expect(h.pasteboard.string(forType: .string) == "C,D\r\n3,4\r\n")
    }

    /// M4.T16: `![alt](image:<id>)` / `(video:<id>)` — the model pointing at the picture already shown in its card —
    /// shows no icon and no alt line (was a stray photo icon + alt line); a remote image still shows its alt text.
    @Test func mediaReferenceByIdRendersNothing() async {
        func height(_ md: String) async -> CGFloat {
            let h = RendererRig.Host(MessageMarkdownView(text: md, streaming: false), look: .light)
            await h.settle(min: 0.5)
            return h.host.fittingSize.height
        }
        let plain = await height("Here's your lighthouse at dusk.")
        let withImage = await height("Here's your lighthouse at dusk.\n\n![Lighthouse at dusk](image:01a1c093-d476)")
        let withVideo = await height("Here's your lighthouse at dusk.\n\n![Waves](video:01a1c093-d476)")
        let remote = await height("Here's your lighthouse at dusk.\n\n![Lighthouse at dusk](https://example.com/a.png)")
        // At most the empty block's spacing remains; no icon, no alt-text line (that line is what `remote` keeps).
        let gap = Spacing.space3 + 1
        #expect(withImage <= plain + gap && withVideo <= plain + gap, "\(plain) \(withImage) \(withVideo)")
        #expect(remote > withImage + 8, "a remote image keeps its alt-text line (\(remote) vs \(withImage))")
    }
}
}  // extension WindowSuites
