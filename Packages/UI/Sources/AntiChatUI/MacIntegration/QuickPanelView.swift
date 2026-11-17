// M8.T13 step 4 (R-106 AC1; components.md QuickPanel, S-22): the panel's content — the composer in compact form (one
// line, Return sends, Esc collapses), the ModeToggle when Evil Mode offers it, and under it the streamed reply
// (Markdown, scrolls) with "Open in AntiChat ⌘O". The field is an AppKit NSTextField so the controller can make it
// first responder in the same pass that orders the panel in (NFR-U9).
import AntiChatDesign
import AppKit
import SwiftUI

struct QuickPanelView: View {
    @Bindable var model: QuickPanelViewModel
    /// Hands the AppKit field to the controller once it exists.
    let onField: (NSTextField) -> Void
    @EffectiveReduceMotion private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                QuickPanelField(text: $model.text, focusRequest: model.focusRequest, onField: onField,
                                onReturn: { model.send() }, onEscape: { model.escape() })
                    .accessibilityIdentifier("quickPanel.field")
                if model.offersEvil {
                    ModeToggle(mode: $model.mode)
                        .fixedSize()
                        .probeID("quickPanel.mode")
                }
                // vq/voice-mac-capture (S-22, IS-1): while the reply streams, Stop sits where the composer's send
                // button would be (the panel had no way to stop an answer but Esc, which only hides it).
                if model.phase == .streaming {
                    SendStopButton(state: .stop, mode: model.mode, queuedPercent: nil, onSend: {}, onStop: { model.stop() })
                        .probeID("quickPanel.stop")
                } else {
                    // VQ (S-22 E1): the typed state had no visible way to send but Return; the composer's Send circle
                    // sits in the same place as Stop (pale and disabled while the field is empty).
                    SendStopButton(state: .send(enabled: !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                   mode: model.mode, queuedPercent: nil, onSend: { model.send() }, onStop: {})
                        .probeID("quickPanel.send")
                }
            }
            .padding(.horizontal, Spacing.space5)
            .frame(height: QuickPanelViewModel.compactSize.height - (model.showsReply ? 40 : 0))
            if model.showsReply {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space4) {
                        // vq/voice-mac-capture (S-22): the question is echoed above its answer (as in the chat
                        // column), so a reopened panel still says what it is answering.
                        if !model.prompt.isEmpty {
                            Text(verbatim: model.prompt)
                                .typeStyle(.body)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(3)
                                .padding(.horizontal, Spacing.space3)
                                .padding(.vertical, Spacing.space2)
                                .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.surfaceSunken))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier("quickPanel.prompt")
                        }
                        // M9.T08 (S-22 capture): the reply renders Markdown like the chat column (headings, lists, code
                        // blocks); the inline-only Text showed "## …" and a run-together code block.
                        Group {
                            if model.reply.text.isEmpty {
                                PendingDot().padding(.vertical, Spacing.space2)
                            } else {
                                MessageMarkdownView(text: model.reply.text, streaming: model.phase == .streaming)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("quickPanel.reply")
                        .probeID("quickPanel.reply")
                    }
                    .padding(Spacing.space5)
                    // VQ (S-22): the panel is as tall as its answer (up to 480 pt); a one-line reply no longer sits
                    // above a large empty band.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.replyContentHeight = $0 }
                }
                // Follows the stream at the bottom, but a short answer starts at the top (it sat under a large empty
                // band, bottom-anchored).
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .alignment)
                HStack {
                    Spacer()
                    Button { model.openInApp() } label: {
                        // VQ (S-22): an accent link on the blue glass read at ~3:1; primary text on a sunken capsule
                        // keeps AA on any desktop behind the panel.
                        HStack(spacing: Spacing.space1) {
                            Text(CopyKey("qp.openInApp")).foregroundStyle(Color.textPrimary)
                            Text(verbatim: "⌘O").foregroundStyle(Color.textSecondary)
                        }
                        .typeStyle(.callout)
                        .padding(.horizontal, Spacing.space3)
                        .padding(.vertical, Spacing.space1)
                        .background(Capsule().fill(Color.surfaceSunken))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("quickPanel.openInApp")
                    .probeID("quickPanel.openInApp")
                }
                .padding(.horizontal, Spacing.space5)
                .padding(.vertical, Spacing.space2)
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .background {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(.thickMaterial)  // VQ (S-22): the regular glass let a blue desktop wash out the text
            // and a canvas-coloured veil over it: the desktop still shows through, but text keeps AA contrast.
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Color.surfaceCanvas.opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(alignment: .topLeading) { QuickPanelCloseButton { model.close() } }
        .onChange(of: model.showsReply) { _, _ in QuickPanelController.shared.resize(animated: !reduceMotion) }
        .onChange(of: model.size.height) { _, _ in QuickPanelController.shared.resize(animated: false) }
        .accessibilityElement(children: .contain)
        .probeID("quickPanel.content")
    }
}

/// The panel's close button in its top-left corner, drawn like the window close button of macOS: a small red dot
/// whose × shows under the pointer (owner 2026-11-17; before that a grey × in the top-right corner).
struct QuickPanelCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .opacity(hovering ? 1 : 0)
                }
                .frame(width: 12, height: 12)
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(5)
        .help(Text(verbatim: "\(CopyKey("panel.close").string()) esc"))
        .accessibilityLabel(Text(CopyKey("panel.close")))
        .accessibilityIdentifier("quickPanel.close")
        .probeID("quickPanel.close")
    }
}

/// One-line AppKit text field: Return → send, Esc → escape (the controller makes it first responder directly).
struct QuickPanelField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    let onField: (NSTextField) -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 20)
        // VQ (S-22): the system placeholder grey (~25 % alpha) fell under 3:1 on the glass; secondary label colour.
        f.placeholderAttributedString = NSAttributedString(
            string: CopyKey("composer.placeholder").string(),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 20)])
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.setAccessibilityIdentifier("quickPanel.field")
        f.setAccessibilityLabel(CopyKey("composer.placeholder").string())  // M9.T01: VoiceOver names the field
        onField(f)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            f.stringValue = text
            if let editor = f.currentEditor(), editor.string != text { editor.string = text }  // an active field editor too
            Self.caretToEnd(f)
        }
        if context.coordinator.focus != focusRequest {
            context.coordinator.focus = focusRequest
            if let w = f.window, w.firstResponder !== f.currentEditor() {
                w.makeFirstResponder(f)
                Self.caretToEnd(f)
            }
        }
    }

    /// VQ (S-22): becoming first responder selects the whole field (AppKit), which read as a highlight over the typed
    /// question; the caret goes after the text instead, as in the composer.
    static func caretToEnd(_ f: NSTextField) {
        guard let editor = f.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickPanelField
        var focus: Int

        init(_ p: QuickPanelField) {
            parent = p
            focus = p.focusRequest
        }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onReturn()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
