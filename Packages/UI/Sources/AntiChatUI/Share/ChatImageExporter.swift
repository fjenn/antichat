// M8.T07 step 5 (R-019 AC1/AC3): Copy as Image. The active path (the last 20 turns at most; a notice says so when
// cut) rendered with ImageRenderer at 2× on the light tokens. A rendering taller than the 16,384 px texture limit is
// split into several PNGs (one pasteboard item each). Evil chats start with the "Evil mode" header bar (text in
// `evil.onBase` on `evil.base`, never colour only).
import AntiChatDesign
import AntiChatStorage
import AppKit
import SwiftUI

@MainActor
enum ChatImageExporter {
    static let maxTurns = 20
    static let scale: CGFloat = 2
    static let maxPixels: CGFloat = 16_384
    static let width: CGFloat = 640

    struct Result {
        var pngs: [Data]
        var truncated: Bool
    }

    static func render(_ doc: ChatDocument) -> Result {
        let turns = Array(doc.turns.suffix(maxTurns))
        var pngs: [Data] = []
        var groups: [[ChatDocument.Turn]] = [turns]
        var first = true
        while !groups.isEmpty {
            let g = groups.removeFirst()
            let view = ChatSnapshotView(doc: doc, turns: g, header: first)
            let r = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .light))
            r.scale = scale
            let height = r.nsImage?.size.height ?? 0
            if height * scale > maxPixels, g.count > 1 {
                let mid = g.count / 2
                groups.insert(contentsOf: [Array(g[..<mid]), Array(g[mid...])], at: 0)
                continue
            }
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                pngs.append(png)
            }
            first = false
        }
        return Result(pngs: pngs, truncated: doc.turns.count > maxTurns)
    }

    static func copy(_ doc: ChatDocument, to pasteboard: NSPasteboard = .general) -> Result {
        let r = render(doc)
        pasteboard.clearContents()
        pasteboard.writeObjects(r.pngs.map { png in
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            return item
        })
        return r
    }
}

struct ChatSnapshotView: View {
    let doc: ChatDocument
    let turns: [ChatDocument.Turn]
    let header: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            if header {
                if doc.isEvil {
                    Text(verbatim: ChatMarkdownRenderer.evilHeader)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.evilOnBase)
                        .padding(.horizontal, Spacing.space3).padding(.vertical, Spacing.space2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color.evilBase))
                }
                Text(verbatim: doc.displayTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.textPrimary)
                if doc.turns.count > turns.count, turns.count == min(doc.turns.count, ChatImageExporter.maxTurns) {
                    Text(CopyText(CopyKey("share.truncated"), ["count": "\(ChatImageExporter.maxTurns)"]))
                        .font(.system(size: 12)).foregroundStyle(Color.textSecondary)
                }
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(verbatim: ChatMarkdownRenderer.roleHeading(t.role)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                    Text((try? AttributedString(markdown: t.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(t.text))
                        .font(.system(size: 14)).foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(t.pictures.enumerated()), id: \.offset) { _, p in
                        if let d = p.data(), let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 320)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        }
                    }
                }
                .padding(t.role == .user ? Spacing.space3 : 0)
                .background(RoundedRectangle(cornerRadius: Radius.lg).fill(t.role == .user ? Color.surfaceSunken : .clear))
            }
        }
        .padding(Spacing.space5)
        .background(Color.surfaceCanvas)
    }
}
