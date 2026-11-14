// InlineEditor (M1.T10 step 6; components.md UserBubble "editing"; ChatGPT FL-13; IS-11): Edit swaps the user
// bubble for a full-width grey editor with [Cancel] [Send]. The message's attachments sit above the field and can
// be removed (the new version drops them; the original keeps them). The `edit.keepsVersions` line says what Send
// does before the user loses anything (IS-11 rule): the old prompt and its reply stay available as version n.
// Return sends, Shift-Return is a new line, Escape cancels.
import AntiChatDesign
import AppKit
import ImageIO
import SwiftUI

struct InlineEditor: View {
    @Binding var text: String
    let attachments: [ConversationModel.MessageAttachment]
    let onRemoveAttachment: (String) -> Void
    let onCancel: () -> Void
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments, onRemove: onRemoveAttachment)
            }
            TextField(text: $text, axis: .vertical) { Text(verbatim: "") }
                .textFieldStyle(.plain)
                .typeStyle(.body)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit { if canSend { onSend() } }
                .tooltip(CopyText(CopyKey("edit.keepsVersions")))
                .accessibilityIdentifier("inlineEditor")
            HStack(spacing: Spacing.space2) {
                Text(CopyKey("edit.keepsVersions"))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("inlineEditorHint")
                Spacer(minLength: Spacing.space2)
                Button(action: onCancel) { Text(CopyText(CopyKey("msg.edit.cancel"))) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("inlineEditorCancel")
                Button(action: onSend) { Text(CopyText(CopyKey("msg.edit.send"))) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSend)
                    .tooltip(CopyText(CopyKey("edit.keepsVersions")))
                    .accessibilityIdentifier("inlineEditorSend")
            }
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        // Focus on the next turn: set inside onAppear the field is not in the window yet and macOS drops it, so Edit
        // left the editor unfocused and typing went nowhere (Q-015 XCUITest catch-up, AT-006).
        .task { await Task.yield(); focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userBubbleEditing")
    }
}

/// A row of message attachments: image thumbnails and file cards (paste cards), optionally removable.
struct AttachmentStrip: View {
    let attachments: [ConversationModel.MessageAttachment]
    var onRemove: ((String) -> Void)?
    var alignment: HorizontalAlignment = .leading
    /// M6.T13 (R-277 AC1/AC2): a sent attachment opens in the window's side panel on click and drags out as a file
    /// named `display_name`.
    @Environment(\.sidePanel) private var panel

    var body: some View {
        HStack(spacing: Spacing.space2) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                AttachmentThumb(attachment: a)
                    .contentShape(Rectangle())
                    .onTapGesture { openInPanel(a) }
                    .accessibilityAction { openInPanel(a) }  // M9.T01
                    .accessibilityIdentifier("messageAttachment.\(i)")  // before the overlay: after it, it stamped over the
                    // remove button's own id (Q-015 r2, the P3 pattern)
                    .onDrag {
                        guard onRemove == nil, let path = a.path else { return NSItemProvider() }
                        return DragOut.itemProvider(for: FileCardItem(url: URL(fileURLWithPath: path), displayName: a.displayName))
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onRemove {
                            Button { onRemove(a.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.textOnAccent, Color.textSecondary)
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .tooltip(CopyText(CopyKey("a11y.dismiss")))
                            .accessibilityLabel(Text(CopyKey("a11y.dismiss")))
                            .accessibilityIdentifier("editAttachmentRemove.\(i)")
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Click and the VoiceOver default action (M9.T01): a sent attachment opens in the side panel.
    private func openInPanel(_ a: ConversationModel.MessageAttachment) {
        guard onRemove == nil, let panel, let path = a.path else { return }
        panel.open(file: URL(fileURLWithPath: path), title: a.displayName)
    }
}

/// One attachment: a 64 pt thumbnail for an image (loaded from its blob path), else a small file card.
struct AttachmentThumb: View {
    let attachment: ConversationModel.MessageAttachment

    @State private var image: NSImage?

    var body: some View {
        Group {
            if attachment.isImage {
                ZStack {
                    Color.surfaceRaised
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(Color.textTertiary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .task(id: attachment.path) { image = attachment.path.flatMap(Self.thumbnail) }
            } else {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "doc.text").foregroundStyle(Color.textSecondary)
                    Text(verbatim: attachment.displayName)
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Spacing.space3)
                .frame(height: 40)
                .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle))
            }
        }
        // Q-015 r5: one element named by the file. Without it the label (and the strip's `messageAttachment.n` id) was
        // stamped on the icon and the name separately: two elements, both "clip.m4a" (AX dump).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: attachment.displayName))
    }

    /// A downscaled copy (128 px), so a large photo is not kept at full size per row.
    static func thumbnail(_ path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
