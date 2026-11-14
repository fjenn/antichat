// M6.T13 step 1 (R-016 AC1): the renderer side of output promotion. A fenced block that OutputPromotion (Harness)
// promotes — > 40 lines, or html / jsx / tsx / svg / mermaid / vega-lite — is shown as an inline ArtifactCardView
// (title, kind, line count) once the reply is done and the block's artifact exists (matched by sha256 through the
// conversation's `\.artifactLookup`); click → the window's SidePanel. A card whose reply just finished in this session
// opens the panel by itself, once (a reloaded chat does not). While the reply streams, and when no artifact exists
// (an interrupted reply, a renderer without a chat store), the block renders as before (code block / Mermaid diagram).
// Mermaid keeps its inline diagram and gets the card under it.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

/// Finds the artifact of a promoted block (sha256 of its source) in the shown chat.
public struct ArtifactLookup: Sendable {
    public var find: @MainActor @Sendable (String) -> PromotedArtifactRef?
    public init(find: @escaping @MainActor @Sendable (String) -> PromotedArtifactRef?) { self.find = find }
}

extension EnvironmentValues {
    /// M6.T13: the conversation's promoted-artifact lookup (nil outside a chat: blocks stay inline).
    @Entry public var artifactLookup: ArtifactLookup? = nil
}

enum LongOutputPromoter {
    /// The promotion of a rendered fence (nil = render it inline).
    static func promotion(language: String?, code: String) -> PromotedBlock? {
        OutputPromotion.classify(language: language, code: code)
    }

    /// A card for a reply that finished moments ago (this session) opens the panel by itself.
    static func isFresh(_ ref: PromotedArtifactRef, now: Date = Date()) -> Bool {
        now.timeIntervalSince(ref.versionCreatedAt) < 15
    }

    static func kindLabel(_ block: PromotedBlock) -> CopyKey {
        block.kind == .html && block.react ? CopyKey("artifact.kind.react") : CopyKey("artifact.kind.\(block.kind.rawValue)")
    }

    static func symbol(_ kind: ArtifactKind, react: Bool) -> String {
        switch kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .doc: "doc.text"
        case .html: react ? "atom" : "globe"
        case .svg: "scribble.variable"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .chart: "chart.bar.xaxis"
        }
    }
}

/// The code block of a promoted fence: the card when its artifact exists, the inline rendering otherwise.
struct PromotedBlockView<Inline: View>: View {
    let block: PromotedBlock
    @ViewBuilder let inline: () -> Inline
    @Environment(\.artifactLookup) private var lookup
    @Environment(\.markdownStream) private var stream  // fix/t05-u5-part5: the block's own flag (observed)
    private var streaming: Bool { stream?.streaming ?? false }
    @Environment(\.sidePanel) private var panel
    @State private var ref: PromotedArtifactRef?

    var body: some View {
        Group {
            if let ref, !streaming {
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    if block.kind == .mermaid { inline() }
                    ArtifactCardView(block: block, ref: ref, onOpen: { open(ref) })
                }
            } else {
                inline()
            }
        }
        .task(id: "\(block.sha256)|\(streaming)") {
            guard !streaming, let lookup else { return }
            // The reply's artifacts are written before `.finished`; a short retry covers the view appearing first.
            for attempt in 0..<20 {
                if let found = lookup.find(block.sha256) {
                    ref = found
                    if LongOutputPromoter.isFresh(found), let panel,
                       panel.autoOpenOnce(found.versions.first { $0.n == found.version }.map { URL(fileURLWithPath: $0.path) }) {
                        open(found)
                    }
                    return
                }
                if attempt == 19 || Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func open(_ ref: PromotedArtifactRef) {
        guard let panel else { return }
        panel.open(ref)
    }
}

/// The inline card of a promoted block (components §4 ArtifactCard; Osaurus `NativeArtifactCardView` layout, ported):
/// kind icon, title, "Kind · N lines", click → panel.
struct ArtifactCardView: View {
    let block: PromotedBlock
    let ref: PromotedArtifactRef
    let onOpen: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: LongOutputPromoter.symbol(block.kind, react: block.react))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ref.title).typeStyle(.bodyEmph).foregroundStyle(Color.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("artifactCardTitle")
                    HStack(spacing: 4) {
                        Text(LongOutputPromoter.kindLabel(block))
                        Text(verbatim: "·")
                        Text(CopyText(CopyKey("artifact.lines"), ["lines": String(block.lineCount)]))
                        if ref.versions.count > 1 {
                            Text(verbatim: "·")
                            Text(CopyText(CopyKey("file.version"), ["n": String(ref.version)]))
                        }
                    }
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                    .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                    .accessibilityIdentifier("artifactCardSubtitle")
                }
                Spacer(minLength: Spacing.space2)
                Image(systemName: "sidebar.right").foregroundStyle(Color.textTertiary)
            }
            .padding(Spacing.space3)
            .frame(maxWidth: 420, alignment: .leading)
            .background(hovering ? Color.surfaceSunken : Color.surfaceCanvas, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.borderSubtle, lineWidth: Stroke.hairline(scale: displayScale)))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(CopyText(CopyKey("artifact.open.a11y"), ["title": ref.title])))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("artifactCard")
    }
}
