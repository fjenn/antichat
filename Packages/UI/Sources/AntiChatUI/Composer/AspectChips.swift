// M4.T07 step 2 (R-030 AC2; S-11): while the Create image chip is in the composer, one shape chip sits beside it; its
// menu holds Square 1:1, Portrait 2:3, Landscape 3:2, Story 9:16, Wide 16:9 and "Any shape". The pick maps to `create_image`'s `aspect` (the
// turn overrides what the model chose, `TurnContext.imageAspect`), is stored with the chat's chips (per chat, across
// relaunches) and is cleared by picking it again or removing Create image. No pick = the model chooses.
import AntiChatDesign
import SwiftUI

public struct AspectChoice: Sendable, Hashable, Identifiable {
    public let ratio: String
    public let copyKey: String
    public var id: String { ratio }

    public static let all: [AspectChoice] = [
        AspectChoice(ratio: "1:1", copyKey: "img.aspect.square"),
        AspectChoice(ratio: "2:3", copyKey: "img.aspect.portrait"),
        AspectChoice(ratio: "3:2", copyKey: "img.aspect.landscape"),
        AspectChoice(ratio: "9:16", copyKey: "img.aspect.story"),
        AspectChoice(ratio: "16:9", copyKey: "img.aspect.wide"),
    ]

    /// width / height.
    public var value: CGFloat {
        let p = ratio.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 && p[1] > 0 ? CGFloat(p[0] / p[1]) : 1
    }
}

/// One compact chip beside Create image: the picture's shape ("Square ▾"), with the five shapes and "Any shape" in
/// its menu. (Five chips in a row squeezed the text field down to "Ask any…".)
struct AspectChips: View {
    let selected: String?
    let onPick: (String?) -> Void

    private var current: AspectChoice? { AspectChoice.all.first { $0.ratio == selected } }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { selected == nil }, set: { on in if on, selected != nil { onPick(nil) } })) {
                Text(CopyKey("img.aspect.auto"))
            }
            .probeID("aspectChip.auto")
            Divider()
            ForEach(AspectChoice.all) { a in
                Toggle(isOn: Binding(get: { selected == a.ratio }, set: { on in if on, selected != a.ratio { onPick(a.ratio) } })) {
                    Text(CopyKey(a.copyKey))
                }
                .accessibilityLabel(Text(CopyText(CopyKey("img.aspect.a11y"), ["aspect": CopyKey(a.copyKey).string(), "ratio": a.ratio])))
                .probeID("aspectChip.\(a.ratio)")
            }
        } label: {
            HStack(spacing: 5) {
                let v = current?.value ?? 1
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: current == nil ? [2, 1.5] : []))
                    .frame(width: v >= 1 ? 12 : 12 * v, height: v >= 1 ? 12 / v : 12)
                    .frame(width: 12, height: 12)
                Text(CopyKey(current?.copyKey ?? "img.aspect.auto")).typeStyle(.subhead).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.space2)
            .frame(height: 28)
            .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(CopyKey(current?.copyKey ?? "img.aspect.auto")))
        .accessibilityShowMenu()
        .accessibilityIdentifier("aspectChips")
    }
}
