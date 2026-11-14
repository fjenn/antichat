// M6.T02 step 4/6 (R-270 AC1/AC2; S-14 answer state): under a reply that read a document in excerpts, a grey line
// `files.usedExcerpts` ("Used excerpts from {name}") with a disclosure listing `files.usedExcerpts.pages` (+ "Keyword
// search only" without an embedder), and `[Read whole file (about N s)]` when the whole file fits the context but not
// the time (`fitsContext && !fitsTime`). Pressing it re-sends the same turn with the documents inline.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct ExcerptNoteView: View {
    let use: MessageProvenance.FileUse
    let onReadWhole: (() -> Void)?
    /// M6.T02 step 7 (R-270 AC3): the ⋯ menu's `files.summariseWhole` (nil = not offered: not the last reply).
    var onSummariseWhole: (() -> Void)? = nil
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(spacing: Spacing.space1) {
                Button { open.toggle() } label: {
                    HStack(spacing: Spacing.space1) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(CopyText(CopyKey("files.usedExcerpts"), ["name": use.name ?? ""]))
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .probeID("excerptNote")
                if let onSummariseWhole {
                    Menu {
                        Button(action: onSummariseWhole) { Text(CopyKey("files.summariseWhole")) }
                            .probeID("summariseWhole")
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                        .accessibilityLabel(Text(CopyKey("chat.more")))  // M9.T01: "More"
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("excerptNoteMore")
                }
            }
            if open {
                Text(CopyText(CopyKey("files.usedExcerpts.pages"), ["pages": use.pages.joined(separator: ", ")]))
                    .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    .probeID("excerptNotePages")
                if use.keywordOnly == true {
                    Text(CopyKey("files.keywordOnly")).typeStyle(.footnote).foregroundStyle(Color.textTertiary)
                }
            }
            if let seconds = use.readWholeSeconds, let onReadWhole {
                Button(action: onReadWhole) {
                    Text(CopyText(CopyKey("files.readWhole"), ["seconds": "\(seconds)"]))
                }
                .controlSize(.small)
                .probeID("readWholeFile")
            }
        }
    }
}
