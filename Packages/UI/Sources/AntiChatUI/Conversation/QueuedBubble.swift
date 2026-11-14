// QueuedBubble (M1.T19 steps 6–7; IS-5 queue, R-014, R-299): a user message that is not sent yet, drawn like a
// UserBubble but dimmed, with a caption and a remove ×:
//   · follow-up (Return during a reply): "Sends after this reply" (`composer.queuedFollowUp`), editable in place
//     (pencil → field, Save / Cancel); sent when the reply ends, oldest first;
//   · held turn (sent before the model is ready): "Sending when Chat is ready (NN%)" (`composer.queuedPct`, or
//     `composer.queued` before any progress), not editable; × cancels it and nothing is sent.
// `QueuedFollowUps` stacks the chat's follow-ups under the transcript, at reading width.
import AntiChatDesign
import AntiChatHarness
import AppKit
import SwiftUI

struct QueuedBubble: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    enum Caption: Equatable {
        case followUp
        /// NN of `composer.queuedPct`; nil = no progress reported yet.
        case ready(Int?)
    }

    let text: String
    let caption: Caption
    /// Saves an edit; nil = not editable (the held turn).
    var onEdit: ((String) -> Void)?
    var onRemove: () -> Void
    var id = "queuedBubble"

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.space1) {
            HStack(spacing: 0) {
                Spacer(minLength: readingWidth * (1 - Layout.userBubbleMaxWidthFraction))
                if editing { editor } else { bubble }
            }
            captionRow
        }
        .accessibilityElement(children: .contain)
        .probeID(id)
    }

    private var bubble: some View {
        Text(verbatim: text)
            .typeStyle(.body)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space2)
            .background(Color.surfaceSunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Color.borderSubtle, style: StrokeStyle(lineWidth: Stroke.control, dash: [4, 3])))
            .fixedSize(horizontal: false, vertical: true)
            .probeID("\(id).text")
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: Spacing.space2) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .typeStyle(.body)
                .lineLimit(1...8)
                .focused($fieldFocused)
                .onSubmit(save)
                .onExitCommand { editing = false }
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space2)
                .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .probeID("\(id).field")
            HStack(spacing: Spacing.space2) {
                Button { editing = false } label: { Text(CopyKey("msg.edit.cancel")) }
                    .accessibilityIdentifier("msg.edit.cancel")
                Button(action: save) { Text(CopyKey("composer.queued.save")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("\(id).save")
            }
            .controlSize(.small)
        }
        .onAppear { draft = text }
        // Q-015 r6 (QueueTests.testFollowUpQueued): inside onAppear the field is not in the window yet and macOS drops
        // the focus request; Edit opened the field without focus and typing went to nothing. Ask again until it holds.
        .task {
            for _ in 0..<20 {
                await Task.yield()
                fieldFocused = true
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if fieldFocused {
                    // Editing continues the message: the caret at its end (focusing a field selects all of it, so the
                    // first keystroke replaced the whole follow-up; r6 p6, "Follow-up two" became ", edited").
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == draft {
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    }
                    return
                }
            }
        }
    }

    private var captionRow: some View {
        HStack(spacing: Spacing.space1) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .regular))
                .accessibilityHidden(true)
            Text(captionText)
                .typeStyle(.footnote)
                .monospacedDigit()
                .probeID("\(id).caption")
            if onEdit != nil, !editing {
                MessageIconButton(symbol: "pencil", tip: CopyText(CopyKey("msg.edit")), id: "\(id).edit") {
                    editing = true
                }
                .probeID("\(id).edit")
            }
            MessageIconButton(symbol: "xmark", tip: CopyText(CopyKey("composer.queued.remove")), id: "\(id).remove",
                              perform: onRemove)
                .probeID("\(id).remove")
        }
        .foregroundStyle(Color.textSecondary)
        .frame(minHeight: 26)
    }

    private var captionText: CopyText {
        switch caption {
        case .followUp: CopyText(CopyKey("composer.queuedFollowUp"))
        case .ready(let p?): CopyText(CopyKey("composer.queuedPct"), ["percent": "\(p)"])
        case .ready(nil): CopyText(CopyKey("composer.queued"))
        }
    }

    private func save() {
        editing = false
        onEdit?(draft)
    }
}

/// The chat's queued follow-ups, in send order, under the transcript (above the composer).
struct QueuedFollowUps: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    @Bindable var model: ConversationModel

    var body: some View {
        if !model.followUps.isEmpty {
            VStack(alignment: .trailing, spacing: Spacing.space2) {
                ForEach(Array(model.followUps.items.enumerated()), id: \.element.id) { i, item in
                    QueuedBubble(text: item.text, caption: .followUp,
                                 onEdit: { model.editQueued(item.id, text: $0) },
                                 onRemove: { model.removeQueued(item.id) }, id: "queuedFollowUp.\(i)")
                }
            }
            .frame(maxWidth: readingWidth)
            .padding(.horizontal, Spacing.space6)
            .padding(.bottom, Spacing.space2)
            .frame(maxWidth: .infinity)
            .background(Color.surfaceCanvas)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.followUpsHeight = $0 }
            .onDisappear { model.followUpsHeight = 0 }
            .transition(.opacity)
        }
    }
}
