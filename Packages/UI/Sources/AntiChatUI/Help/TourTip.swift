// M10.T07 step 3 (R-303 AC3): "What can AntiChat do?" in the first empty chat after onboarding, built from the
// installed packs; [Got it] invalidates it for good. TipKit's datastore lives under the AntiChat container
// (Application Support/AntiChat/Tips), so Remove everything / Uninstall delete it with the rest. Not shown in Evil
// or incognito chats (the caller decides).
import AntiChatDesign
import Foundation
import SwiftUI
import TipKit

struct TourTip: Tip {
    let packs: Set<SuggestionPack>

    /// Pure (unit-tested): chat always, then the installed packs, then files.
    static func itemKeys(_ packs: Set<SuggestionPack>) -> [String] {
        var keys = ["tour.item.chat"]
        if packs.contains(.voice) { keys.append("tour.item.voice") }
        if packs.contains(.photo) { keys.append("tour.item.photo") }
        if packs.contains(.video) { keys.append("tour.item.video") }
        keys.append("tour.item.files")
        return keys
    }

    var title: Text { Text(CopyKey("tour.title")) }
    /// `text.secondary`, not TipKit's own secondary label grey (the audit: "Contrast nearly passed" on S-05).
    /// VQ round 65: one line of capability nouns ("Chat, Voice, Pictures, Your files, all on this Mac"), not the
    /// suggestion rows' own prompts again ("Talk to me", "Make a picture" sat in the card and right under it).
    var message: Text? {
        Text(verbatim: Self.line(packs))
            .foregroundStyle(Color.textSecondary)
    }

    /// The card's line for `packs` (pure).
    static func line(_ packs: Set<SuggestionPack>) -> String {
        CopyKey("tour.line").string(["items": itemKeys(packs).map { CopyKey($0).string() }.joined(separator: ", ")])
    }
    var image: Image? { Image(systemName: "sparkles") }
    var actions: [Action] { [Action(id: "gotIt") { Text(CopyKey("tour.dismiss")) }] }
    var options: [any TipOption] { [Tips.IgnoresDisplayFrequency(true)] }

    /// Once per process, before any TipView appears.
    @MainActor static func configure(container: URL) {
        guard !configured else { return }
        configured = true
        let dir = container.appendingPathComponent("Tips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Tips.configure([.datastoreLocation(.url(dir))])
    }

    @MainActor private static var configured = false
}

struct TourTipView: View {
    let packs: Set<SuggestionPack>
    /// Q-015 r3: TipView collapses a dismissed tip to an empty, zero-size element that stayed in the accessibility tree
    /// (and in the window's layout) for good; the view goes away once TipKit says the tip no longer displays.
    @State private var displays = true

    var body: some View {
        let tip = TourTip(packs: packs)
        Group {
            if displays {
                TipView(tip) { action in
                    if action.id == "gotIt" { tip.invalidate(reason: .actionPerformed) }
                }
                .tipViewStyle(TourTipStyle())
                .probeID("tourTip")
            }
        }
        .task {
            for await shown in tip.shouldDisplayUpdates { displays = shown }
        }
    }
}

/// M10 visual QA: the minimal card. TipKit's default style added a full-width accent "Got it" under the text (extra
/// chrome ChatGPT's empty chat does not have, and white on the pale Dark accent at ~3:1). One quiet row instead: the
/// glyph, the title and the item line, and a single close control that *is* Got it (it invalidates the tip for good,
/// R-303 AC3; VoiceOver and the UI test find it by that name). VQ round 65: it sits at the foot of the empty chat
/// (not over the headline), borderless, with a standard 28 pt close button.
struct TourTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        TourCard(image: configuration.image, title: configuration.title, message: configuration.message) {
            configuration.tip.invalidate(reason: .actionPerformed)
        }
    }
}

/// The card itself (also rendered on its own by the visual-QA tests).
struct TourCard: View {
    let image: Image?
    let title: Text?
    let message: Text?
    let onClose: () -> Void

    @State private var closeHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            image?
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title?
                    .font(.system(size: 14, weight: .semibold))  // type.callout, emphasised
                    .foregroundStyle(Color.textPrimary)
                message?
                    .typeStyle(.callout)  // 14 pt (was 13: "the secondary text is small")
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.space2)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(closeHovered ? Color.textPrimary : Color.textSecondary)
                    .frame(width: 28, height: 28)  // the standard close-button hit area (was 24 with an 11 pt glyph)
                    .background(Circle().fill(closeHovered ? Color.surfaceSelected : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .tooltip(CopyText(CopyKey("tour.dismiss")))
            .accessibilityLabel(Text(CopyKey("tour.dismiss")))
            .probeID("tour.dismiss")  // the accessibility id, plus the DEBUG probe anchor (vq-m9 m10 dismissed shot)
        }
        .padding(.leading, Spacing.space4)
        .padding(.trailing, Spacing.space2)
        .padding(.vertical, Spacing.space2)
        .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

/// The app target's entry point (AppDelegate): configure TipKit once, with the datastore in the AntiChat container.
public enum TourTips {
    @MainActor public static func configure(container: URL) { TourTip.configure(container: container) }
}
