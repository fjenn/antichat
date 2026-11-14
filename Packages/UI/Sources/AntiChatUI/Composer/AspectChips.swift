// M4.T07 step 2 (R-030 AC2; S-11): while the Create image chip is in the composer, five aspect chips sit beside it —
// Square 1:1, Portrait 2:3, Landscape 3:2, Story 9:16, Wide 16:9. The pick maps to `create_image`'s `aspect` (the
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

struct AspectChips: View {
    @Environment(\.accentPreset) private var accentPreset
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: Spacing.space1) {
            ForEach(AspectChoice.all) { a in
                let on = selected == a.ratio
                Button { onPick(a.ratio) } label: {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).strokeBorder(lineWidth: 1.2)
                            .frame(width: a.value >= 1 ? 12 : 12 * a.value, height: a.value >= 1 ? 12 / a.value : 12)
                            .frame(width: 12, height: 12)
                        Text(CopyKey(a.copyKey)).typeStyle(.footnote).fixedSize()
                    }
                    .padding(.horizontal, Spacing.space2).padding(.vertical, 3)
                    .foregroundStyle(on ? accentPreset.color : Color.textSecondary)
                    .background(Capsule().fill(on ? accentPreset.color.opacity(0.12) : Color.clear))
                    .overlay(Capsule().strokeBorder(on ? accentPreset.color.opacity(0.5) : Color.borderSubtle, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityLabel(Text(CopyText(CopyKey("img.aspect.a11y"), ["aspect": CopyKey(a.copyKey).string(), "ratio": a.ratio])))
                .probeID("aspectChip.\(a.ratio)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aspectChips")
    }
}
