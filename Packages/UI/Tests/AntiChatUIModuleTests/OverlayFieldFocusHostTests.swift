// fix/overlay-field-focus: SwiftUI text fields over the chat column while the composer (an AppKit NSTextView) has the
// focus. The real MainWindow + ChatSessions in an NSWindow, as the app's MainWindowHost wires it.
//   · Click: the viewer's "Describe the change" capsule had a stroked shape overlaid on the field. SwiftUI hit-tests an
//     overlaid shape by its area, so AppKit's hit test at the field returned the column's NSHostingView, never the
//     field's AppKit text field: the click was SwiftUI's, the field never got mouseDown and the composer kept the
//     focus. The find bar had the same overlay. A click lands on the view `hitTest` returns, so the test checks that.
//   · Edit (programmatic): the field takes the focus from the composer when the viewer opens for an edit, and only then.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct OverlayFieldFocusHostTests {
    @MainActor struct Rig {
        let state: WindowState
        let sessions: ChatSessions
        let window: NSWindow
        var model: ConversationModel { sessions.model(for: state.currentChatID!) }
        var host: NSView { window.contentView! }
    }

    private func make() async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let script = #"{"t":"textDelta","v":"Hello there.","delayMs":20}"#
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindow(state: state, slots: sessions.slots)
            .environment(\.reduceMotionOverride, true))
        BackgroundRun.present(window)
        await pump(400)
        state.send("Hi", reduceMotion: true, turn: sessions.slots.startTurn)
        await pump(800)
        return Rig(state: state, sessions: sessions, window: window)
    }

    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    static func field(in view: NSView, placeholder: String) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable, f.placeholderString == placeholder { return f }
        for s in view.subviews { if let f = field(in: s, placeholder: placeholder) { return f } }
        return nil
    }

    static func composer(in view: NSView) -> ComposerNSTextView? {
        if let v = view as? ComposerNSTextView { return v }
        for s in view.subviews { if let f = composer(in: s) { return f } }
        return nil
    }

    /// True when a click at the middle of `field` is delivered to it (or to its field editor, while it is editing).
    static func clickReaches(_ field: NSView, in host: NSView) -> Bool {
        let p = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        return host.hitTest(host.superview?.convert(p, from: nil) ?? p)?.isDescendant(of: field) == true
    }

    static func editing(_ window: NSWindow) -> NSTextField? { (window.firstResponder as? NSText)?.delegate as? NSTextField }

    private func openViewer(_ rig: Rig, edit: Bool) throws {
        let png = try ImageJobCardTests.gradient()
        rig.model.openImageViewer(ImageViewerTarget(paths: [png], selected: 0, artifactID: "a1", current: png, focusDescribe: edit))
    }

    @Test func describeFieldTakesTheFocusFromTheComposerOnEdit() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        let composer = try #require(Self.composer(in: rig.host))
        #expect(rig.window.firstResponder === composer, "the composer has the focus after the send")
        try openViewer(rig, edit: true)
        await pump(1200)
        let describe = try #require(Self.field(in: rig.host, placeholder: CopyKey("editor.describe").string()))
        #expect(Self.editing(rig.window) === describe, "Edit opens the viewer with Describe the change focused")
    }

    @Test func viewerWithoutEditLeavesTheComposerFocused() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        let composer = try #require(Self.composer(in: rig.host))
        try openViewer(rig, edit: false)
        await pump(1200)
        #expect(Self.field(in: rig.host, placeholder: CopyKey("editor.describe").string()) != nil)
        #expect(rig.window.firstResponder === composer, "opening the picture never takes the focus")
    }

    @Test func clickOnDescribeFieldReachesTheTextField() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        try openViewer(rig, edit: false)
        await pump(1200)
        let describe = try #require(Self.field(in: rig.host, placeholder: CopyKey("editor.describe").string()))
        #expect(Self.clickReaches(describe, in: rig.host),
                "a click on the field is the field's (was the column's NSHostingView: the capsule's stroke overlay took it)")
        // And the click focuses it while the composer holds the focus: AppKit's mouseDown path for the hit view.
        let composer = try #require(Self.composer(in: rig.host))
        _ = rig.window.makeFirstResponder(composer)
        #expect(describe.acceptsFirstResponder && rig.window.makeFirstResponder(describe))
        #expect(Self.editing(rig.window) === describe)
    }

    @Test func clickOnFindFieldReachesTheTextField() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        rig.model.find.present()
        await pump(600)
        let find = try #require(Self.field(in: rig.host, placeholder: CopyKey("find.placeholder").string()))
        #expect(Self.clickReaches(find, in: rig.host), "the find bar's stroke overlay no longer takes the click")
    }
}
}
