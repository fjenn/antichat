// PasteAttachmentCard (M1.T08 step 6; IS-6 "long pastes become attachments", F-107): a paste over 10,000
// characters becomes a ~120×96 tile in the composer tray (AttachmentTile size, components.md §2) labelled
// `composer.pasteCard`. Click opens a read-only viewer sheet; × removes it.
import AntiChatDesign
import SwiftUI

struct PasteAttachmentCard: View {
    let attachment: ComposerAttachment
    let onOpen: () -> Void
    let onRemove: () -> Void

    static let size = CGSize(width: 140, height: 96)  // ChatGPT ~130×95 (FL-06); fits "Pasted text · 10,001 characters"
    @State private var hovering = false

    static func countLabel(_ attachment: ComposerAttachment) -> CopyText {
        CopyText(CopyKey("composer.pasteCard"),
                 ["count": attachment.characterCount.formatted(.number.grouping(.automatic))])
    }

    /// The first few non-empty lines, for the tile preview.
    private var preview: String {
        String(attachment.text.prefix(240))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(verbatim: preview)
                        .typeStyle(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Text(Self.countLabel(attachment))
                        .typeStyle(.caption)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.space2)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(hovering ? Color.surfaceHover : Color.surfaceCanvas)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("pasteCard")
            .accessibilityLabel(Text(Self.countLabel(attachment)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(CopyKey("composer.pasteCard.remove")), onRemove)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.buttonPrimaryFg)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.buttonPrimaryBg))
                    .contentShape(Circle().inset(by: -5))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help(CopyKey("composer.pasteCard.remove").string())
            .accessibilityIdentifier("pasteCardRemove")
            .accessibilityLabel(Text(CopyKey("composer.pasteCard.remove")))
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

/// Read-only viewer for a pasted-text card.
struct PasteViewerSheet: View {
    let attachment: ComposerAttachment
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text(CopyKey("composer.pasteCard.title"))
                    .typeStyle(.title3)
                    .foregroundStyle(Color.textPrimary)
                Text(PasteAttachmentCard.countLabel(attachment))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button(action: onDone) { Text(CopyKey("composer.pasteCard.done")) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pasteViewerDone")
            }
            ReadOnlyTextView(text: attachment.text)
                .background(Color.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .accessibilityIdentifier("pasteViewerText")
        }
        .padding(Spacing.space5)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 360, idealHeight: 520)
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)  // keeps pasteViewerDone / pasteViewerText (Q-015 catch-up)
        .accessibilityIdentifier("pasteViewer")
    }
}

/// A selectable, non-editable NSTextView (large pastes scroll without SwiftUI Text layout cost).
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: Spacing.space3, height: Spacing.space3)
            tv.font = TypeToken.code.nsFont()
            tv.textColor = .textPrimary
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
    }
}
