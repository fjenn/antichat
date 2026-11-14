// R65 (VQ-M10 S-24 regression, f4de99349): [Always allow] and [Deny] stopped answering the ApprovalCard in the vq-j12 /
// vq-inject runs (the card stayed pending with live buttons), and the S-10 Sources button stopped opening the panel.
// Cause (DEBUG builds only): the probe anchor (`probeID`) is an NSViewRepresentable, and in the app's window SwiftUI's
// hit test answered with the anchor's platform-view host for the whole button frame, so the probe's click went to the
// anchor (whichever host was stacked last) and the button never fired; fixed with `.allowsHitTesting(false)` on the
// anchor (ProbeAnchor.swift). An in-process NSHostingView window does not reproduce that stacking (clicks fire there
// with or without the fix), so the end-to-end guard is the vq-m7 legs: vq-j12 (Deny / Allow once / Always allow by
// click), vq-inject (Deny on the untrusted card) and vq-chat (pillsMatchPanel). This suite pins what can be pinned
// here: every button answers a click with its own answer, also after a Color mode flip (the captures' setLook) and on
// the untrusted card (no Always allow there), and no anchor host answers a direct hit test.
import AntiChatHarness
import AppKit
import Defaults
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ApprovalCardActivationTests {
    final class Answers { var list: [ApprovalAnswer] = [] }
    @Observable final class Shown { var request: ToolApprovalRequest? }

    /// The card under a reply as the transcript shows it: nothing at first, the approval a moment later.
    struct Host: View {
        let shown: Shown
        let answers: Answers
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Using Write note")
                    if let request = shown.request {
                        ApprovalCardView(request: request) { answers.list.append($0); shown.request = nil }
                    }
                }
                .padding(24)
            }
            .frame(width: 640, height: 300)
            .appearanceFromSettings()
        }
    }

    struct Rig {
        let window: NSWindow
        let answers: Answers
    }

    private func make(untrusted: Bool = false) async -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let answers = Answers()
        let shown = Shown()
        let request = ToolApprovalRequest(id: "c1", tool: "write_note", argumentsJSON: #"{"title":"Groceries","text":"Buy milk"}"#,
                                          sideEffect: .write, untrusted: untrusted)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(shown: shown, answers: answers))
        BackgroundRun.present(window)
        await pump(300)
        shown.request = request
        await pump(400)
        return Rig(window: window, answers: answers)
    }

    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    /// A left click at the centre of the button's frame (the SettingsProbe `tracking: false` delivery).
    private func click(_ rig: Rig, _ id: String) -> Bool {
        rig.window.contentView?.layoutSubtreeIfNeeded()
        guard let f = UIProbeRegistry.frame(id, in: rig.window) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: f.midX, y: f.midY), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
            rig.window.sendEvent(e)
        }
        return true
    }

    /// What AppKit's hit test answers at the centre of `id` (the view a real click is delivered to).
    private func hit(_ rig: Rig, _ id: String) -> String {
        rig.window.contentView?.layoutSubtreeIfNeeded()
        guard let f = UIProbeRegistry.frame(id, in: rig.window), let root = rig.window.contentView?.superview else { return "no frame" }
        return root.hitTest(CGPoint(x: f.midX, y: f.midY)).map { String(describing: type(of: $0)) } ?? "nil"
    }

    nonisolated static let buttons: [(String, ApprovalAnswer)] = [("approveAllowOnce", .allowOnce), ("approveAlways", .always), ("approveDeny", .deny)]

    @Test(arguments: buttons)
    func noProbeAnchorTakesTheClick(_ id: String, _ answer: ApprovalAnswer) async throws {
        let rig = await make()
        defer { rig.window.close() }
        #expect(await until(3) { UIProbeRegistry.frame(id, in: rig.window) != nil }, "\(id) is shown")
        let view = hit(rig, id)
        #expect(!view.contains("ProbeAnchor"), "\(id): the click lands on \(view)")
        // Whatever order SwiftUI stacks the platform views in: no anchor's host answers a hit test anywhere on itself.
        for v in UIProbeRegistry.anchors[id]?.compactMap(\.view) ?? [] {
            guard let host = v.superview, let parent = host.superview else { continue }
            let inParent = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: parent)
            let answer = host.hitTest(inParent)
            #expect(answer == nil, "\(id): the anchor's host \(type(of: host)) answered the hit test with \(answer.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }

    @Test(arguments: buttons)
    func everyButtonAnswersOnAClick(_ id: String, _ answer: ApprovalAnswer) async throws {
        let rig = await make()
        defer { rig.window.close() }
        #expect(await until(3) { UIProbeRegistry.frame(id, in: rig.window) != nil }, "\(id) is shown")
        #expect(click(rig, id))
        #expect(await until(2) { !rig.answers.list.isEmpty }, "\(id): a click answers the card")
        #expect(rig.answers.list == [answer])
    }

    @Test func everyButtonAnswersAfterTheColorModeFlips() async throws {
        for (id, answer) in Self.buttons {
            let rig = await make()
            defer { rig.window.close() }
            #expect(await until(3) { UIProbeRegistry.frame(id, in: rig.window) != nil })
            let saved = Defaults[.colorMode]
            Defaults[.colorMode] = "dark"
            await pump(300)
            Defaults[.colorMode] = saved
            await pump(300)
            #expect(click(rig, id))
            #expect(await until(2) { !rig.answers.list.isEmpty }, "\(id): a click answers after a Color mode change")
            #expect(rig.answers.list == [answer])
        }
    }

    @Test func denyAnswersOnAClickWhenUntrusted() async throws {
        let rig = await make(untrusted: true)
        defer { rig.window.close() }
        #expect(await until(3) { UIProbeRegistry.frame("approveDeny", in: rig.window) != nil })
        #expect(UIProbeRegistry.frame("approveAlways", in: rig.window) == nil, "no lasting Always allow when untrusted")
        #expect(click(rig, "approveDeny"))
        #expect(await until(2) { !rig.answers.list.isEmpty })
        #expect(rig.answers.list == [.deny])
    }
}
}
