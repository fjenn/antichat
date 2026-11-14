// ComposerInteractionTests (M1.T08, AT-002 in-process legs). They drive the real ComposerView: the
// NSTextView receives synthesized key events and pastes inside an offscreen NSWindow, as in SpikeProbe (Q-015).
// XCUITest cannot see AntiChat's windows in this session (Q-023), so these tests carry legs (2)–(6) until
// App/UITests/ComposerTests runs.
import AppKit
import Defaults
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ComposerInteractionTests {
    @MainActor final class Host {
        let model: ComposerModel
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        var sent: [ComposerSubmission] = []
        /// This host's own pasteboard (never the general one: parallel tests and other processes share that).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("antichat-test-\(UUID().uuidString)"))

        init(model: ComposerModel? = nil, width: CGFloat = 640, height: CGFloat = 820) {
            let model = model ?? ComposerModel()
            self.model = model
            hosting = NSHostingView(rootView: AnyView(
                VStack { Spacer(minLength: 0); ComposerView(model: model) }
                    .frame(width: width, height: height)))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.contentView = hosting
            model.onSend = { [unowned self] in self.sent.append($0) }
            settle()
            textView.pasteboard = pasteboard
            _ = window.makeFirstResponder(textView)
        }

        var scrollView: NSScrollView { Self.find(NSScrollView.self, in: hosting)! }
        var textView: ComposerNSTextView { scrollView.documentView as! ComposerNSTextView }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let v = view as? T, v.accessibilityIdentifier() == "composerScroll" || T.self != NSScrollView.self {
                return v
            }
            for s in view.subviews { if let f = find(type, in: s) { return f } }
            return nil
        }

        func settle() {
            for _ in 0..<4 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        func key(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
            if flags.contains(.command), textView.performKeyEquivalent(with: e) { settle(); return }
            textView.keyDown(with: e)
            settle()
        }

        func returnKey(_ flags: NSEvent.ModifierFlags = []) { key("\r", keyCode: 36, flags) }

        func type(_ s: String) {
            textView.insertText(s, replacementRange: textView.selectedRange())
            settle()
        }

        func paste(_ s: String) {
            pasteboard.clearContents()
            pasteboard.setString(s, forType: .string)
            textView.paste(nil)
            settle()
        }
    }

    // (2) growth 1 → 12 lines, then scroll; bottom row

    @Test func leg2_growsExactlyTwelveLinesThenScrolls() {
        let h = Host()
        h.type("line 1")
        var heights = [h.scrollView.frame.height]
        #expect(!h.model.usesBottomRow, "one line: controls beside the text")
        for n in 2...15 {
            h.returnKey(.shift)
            h.type("line \(n)")
            heights.append(h.scrollView.frame.height)
        }
        #expect(h.model.lineCount == 15)
        #expect(heights[0] == 24)
        for n in 1..<12 { #expect(heights[n] - heights[n - 1] == 24, "line \(n + 1)") }
        #expect(heights[11] == 288)
        for n in 12..<15 { #expect(heights[n] == 288, "stops at 12 lines") }
        #expect(h.textView.frame.height > h.scrollView.frame.height + 24, "the 15-line text scrolls inside the field")
        #expect(h.model.usesBottomRow, "multi-line: controls on the bottom row")
        #expect(h.sent.isEmpty)
    }

    @Test func leg2_wrappedSingleParagraphUsesTheBottomRow() {
        let h = Host()
        h.type(String(repeating: "wrap ", count: 60))
        #expect(h.model.textWraps)
        #expect(h.model.usesBottomRow)
        let used = h.textView.layoutManager!.usedRect(for: h.textView.textContainer!).height
        #expect(h.model.lineCount >= 2)
        #expect(CGFloat(h.model.lineCount) * 24 == used, "line count re-measured at the bottom-row width")
        #expect(h.scrollView.frame.height == used)
        h.textView.selectAll(nil)
        h.textView.deleteBackward(nil)
        h.settle()
        #expect(!h.model.usesBottomRow, "back to one row when the text is cleared")
    }

    // (3) send → Stop → done

    @Test func leg3_returnSendsAndTheButtonIsStopImmediately() {
        let h = Host()
        #expect(h.model.trailingButton == .voice)
        h.type("hi")
        #expect(h.model.trailingButton == .send(enabled: true))
        h.returnKey()
        #expect(h.sent.map(\.markdown) == ["hi"])
        #expect(h.model.trailingButton == .stop)
        #expect(h.textView.string.isEmpty)
        h.model.turnFinished()
        #expect(h.model.trailingButton == .voice)
    }

    // (4) keys

    @Test func leg4_defaultReturnSendsShiftReturnNewline() {
        let h = Host()
        h.type("a")
        h.returnKey(.shift)
        h.type("b")
        #expect(h.sent.isEmpty)
        #expect(h.textView.string == "a\nb")
        h.returnKey()
        #expect(h.sent.map(\.markdown) == ["a\nb"])
    }

    @Test func leg4_commandEnterSetting() {
        Defaults[.sendWithCommandEnter] = true
        defer { Defaults.reset(.sendWithCommandEnter) }
        let h = Host()
        h.type("a")
        h.returnKey()
        h.type("b")
        #expect(h.sent.isEmpty, "Return inserts a newline")
        #expect(h.textView.string == "a\nb")
        h.returnKey(.command)
        #expect(h.sent.map(\.markdown) == ["a\nb"], "⌘Return sends")
    }

    // (5) rich text

    @Test func leg5_boldRunRendersBoldByDefaultAndPlainModeIsUnstyled() throws {
        let h = Host()
        h.type("make **this** bold")
        #expect(h.model.debugBoldRunCount == 1)
        let at = (h.textView.string as NSString).range(of: "this").location
        let font = try #require(h.textView.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold) || font.fontName.contains("Semibold"))
        h.returnKey()
        #expect(h.sent.last?.markdown == "make **this** bold")

        Defaults[.plainTextComposer] = true
        defer { Defaults.reset(.plainTextComposer) }
        let p = Host()
        p.type("make **this** bold")
        #expect(p.model.debugBoldRunCount == 0)
        let f = p.textView.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        #expect(f == TypeToken.body.nsFont())
        p.returnKey()
        #expect(p.sent.last?.markdown == "make **this** bold", "payload is Markdown in plain mode too")
    }

    // (6) paste

    @Test func leg6_pasteOver10000BecomesACardAnd10000StaysInline() {
        let h = Host()
        h.paste(String(repeating: "x", count: 10_001))
        #expect(h.model.attachments.count == 1)
        #expect(h.textView.string.isEmpty, "not inserted as text")
        #expect(h.model.usesBottomRow)
        h.model.removeAttachment(id: h.model.attachments[0].id)
        h.settle()
        #expect(h.model.attachments.isEmpty)

        h.paste(String(repeating: "y", count: 10_000))
        #expect(h.model.attachments.isEmpty)
        #expect(h.textView.string.count == 10_000)
    }

    @Test func leg6_richClipboardIsPastedAsPlainMarkdownSource() {
        let h = Host()
        h.pasteboard.clearContents()
        let rich = NSAttributedString(string: "red", attributes: [.foregroundColor: NSColor.red,
                                                                  .font: NSFont.systemFont(ofSize: 30)])
        h.pasteboard.writeObjects([rich])
        h.textView.paste(nil)
        h.settle()
        #expect(h.textView.string == "red")
        let f = h.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f?.pointSize == TypeToken.body.size, "foreign attributes are dropped")
    }

    // Q-015 catch-up (XCUITest AT-001 legs 5–6): the empty-state composer docks after the first send, which builds a
    // new field; the focus must move to it, or the next keystroke goes nowhere.
    @Observable final class Dock { var docked = false }

    @Test func dockedFieldKeepsTheFocus() {
        let model = ComposerModel()
        let dock = Dock()
        let hosting = NSHostingView(rootView: AnyView(DockSwitch(model: model, dock: dock).frame(width: 640, height: 600)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        func settle() {
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        settle()
        let first = Host.find(NSScrollView.self, in: hosting)?.documentView as? ComposerNSTextView
        #expect(first != nil)
        #expect(window.firstResponder === first, "a new window composer takes the focus")
        let search = NSTextField()
        hosting.addSubview(search)
        _ = window.makeFirstResponder(search)
        dock.docked = true
        settle()
        let second = Host.find(NSScrollView.self, in: hosting)?.documentView as? ComposerNSTextView
        #expect(second != nil && second !== first, "the docked composer is a new field")
        #expect(window.firstResponder !== second, "never takes the focus from another control")
        search.removeFromSuperview()
        _ = window.makeFirstResponder(second)
        dock.docked = false
        settle()
        let third = Host.find(NSScrollView.self, in: hosting)?.documentView as? ComposerNSTextView
        #expect(third != nil && third !== second)
        #expect(window.firstResponder === third, "the focus follows the composer to its new field")
    }

    // Q-015 r6 (WindowLayout disclaimer, J08's second send): the dock is animated, so the empty-state field stays in
    // the window for the animation and sees the send's focus request too. Only the composer's newest field takes it,
    // and a focused field that leaves hands the focus to the newest one.
    @Test func animatedDockLeavesTheFocusOnTheDockedField() {
        let model = ComposerModel()
        let dock = Dock()
        let hosting = NSHostingView(rootView: AnyView(DockSwitch(model: model, dock: dock).frame(width: 640, height: 600)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        func settle(_ seconds: Double = 0.12) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            } while Date() < end
        }
        settle()
        let first = Host.find(NSScrollView.self, in: hosting)?.documentView as? ComposerNSTextView
        _ = window.makeFirstResponder(first)
        #expect(window.firstResponder === first)
        model.text = "Message 0"
        model.onSend = { _ in withAnimation(.linear(duration: 0.4)) { dock.docked = true } }
        #expect(model.send())  // bumps focusRequest, then docks (animated)
        settle(1.0)  // past the animation: the empty-state field has left the window
        let docked = Host.find(NSScrollView.self, in: hosting)?.documentView as? ComposerNSTextView
        #expect(docked != nil && docked !== first, "the docked composer is a new field")
        #expect(first?.window == nil, "the empty-state field is gone after the animation")
        #expect(window.firstResponder === docked, "the docked field has the focus after the first send")
    }

    @Test func focusedFieldLeavingHandsTheFocusToTheNewestField() {
        let model = ComposerModel()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let old = ComposerNSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 22))
        let new = ComposerNSTextView(frame: CGRect(x: 0, y: 40, width: 200, height: 22))
        ComposerFocusOwner.adopt(old, for: model)
        root.addSubview(old)
        _ = window.makeFirstResponder(old)
        ComposerFocusOwner.adopt(new, for: model)
        root.addSubview(new)
        #expect(ComposerFocusOwner.owns(new))
        #expect(!ComposerFocusOwner.owns(old), "an outgoing field no longer answers focus requests")
        old.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(window.firstResponder === new, "the focus moved to the composer's current field")
        // A text field the user focused meanwhile keeps it.
        let other = ComposerModel()
        let a = ComposerNSTextView(frame: CGRect(x: 0, y: 80, width: 200, height: 22))
        let b = ComposerNSTextView(frame: CGRect(x: 0, y: 120, width: 200, height: 22))
        ComposerFocusOwner.adopt(a, for: other)
        root.addSubview(a)
        _ = window.makeFirstResponder(a)
        ComposerFocusOwner.adopt(b, for: other)
        root.addSubview(b)
        let search = NSTextField(frame: CGRect(x: 0, y: 200, width: 200, height: 22))
        root.addSubview(search)
        a.removeFromSuperview()
        _ = window.makeFirstResponder(search)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(window.firstResponder !== b, "never takes the focus from a text field")
    }

    // fix/overlay-field-focus: a window deallocated while an outgoing composer field holds its focus. The field's
    // viewWillMove(toWindow: nil) runs inside NSWindow's dealloc; the hand-off took a weak reference to that window and
    // the runtime aborted the whole test process ("Cannot form weak reference to instance … NSKVONotifying_NSWindow").
    @Test func windowDeallocatedWithAFocusedOutgoingFieldDoesNotAbort() {
        let model = ComposerModel()
        weak var gone: NSWindow?
        autoreleasepool {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = root
            let old = ComposerNSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 22))
            let new = ComposerNSTextView(frame: CGRect(x: 0, y: 40, width: 200, height: 22))
            ComposerFocusOwner.adopt(old, for: model)
            root.addSubview(old)
            _ = window.makeFirstResponder(old)
            ComposerFocusOwner.adopt(new, for: model)
            root.addSubview(new)
            #expect(window.firstResponder === old)
            gone = window
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(gone == nil, "the window is gone and the process is still running")
    }

    struct DockSwitch: View {
        let model: ComposerModel
        let dock: Dock
        var body: some View {
            if dock.docked {
                VStack { Spacer(minLength: 0); ComposerView(model: model) }
            } else {
                VStack { ComposerView(model: model); Spacer(minLength: 0) }.padding(.top, 40)
            }
        }
    }
}
}  // extension WindowSuites
