// M5.T09 step 5 (R-290 AC3, R-044 AC1, R-292): [Change] on the plan card opens this inline — length (Short / Medium,
// only what the tier allows; hidden when Advanced → exact length is set), shape (Square / Portrait / Landscape) and the
// Sound chip where the tier has an audio model and the chat is Normal (VideoSound). Each pick re-plans and the card's
// estimate line updates at once. No steps, resolution or exact length here (R-044 AC2: Settings → Advanced only).
// Chips follow the composer's AspectChips (accent fill when on, subtle border when off).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct VideoPresetPicker: View {
    let model: VideoPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let lengths = model.plan.options?.lengths, lengths.count > 1, !model.plan.exactLength {
                row {
                    ForEach(lengths, id: \.self) { l in
                        VideoPresetChip(title: CopyText(CopyKey(l.copyKey)), on: model.plan.spec?.length == l,
                                        id: "videoPlan.length.\(l.rawValue)") { model.pick(length: l) }
                    }
                }
            }
            // vq/voice-mac-capture (S-12): Sound joins the shape row (it sat alone on a row of its own).
            row {
                ForEach(model.plan.options?.shapes ?? VideoShape.allCases, id: \.self) { s in
                    VideoPresetChip(title: CopyText(CopyKey(s.copyKey)), on: model.plan.spec?.shape == s,
                                    id: "videoPlan.shape.\(s.rawValue)", shape: s) { model.pick(shape: s) }
                }
                if model.plan.soundChip {
                    Divider().frame(height: 14).padding(.horizontal, Spacing.space1)
                    VideoPresetChip(title: CopyText(CopyKey(model.sound ? "video.soundOn" : "video.sound")), on: model.sound,
                                    id: "videoPlan.sound", symbol: model.sound ? "speaker.wave.2" : "speaker.slash") {
                        model.pick(sound: !model.sound)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("videoPresetPicker")
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        // At its ideal width with a pixel of room: a squeezed row clipped the selected chip's border (S-12).
        HStack(spacing: Spacing.space1) { content() }
            .padding(.horizontal, 1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// One preset chip (selected = accent tint), optionally with the shape's outline or a symbol.
struct VideoPresetChip: View {
    @Environment(\.accentPreset) private var accentPreset
    let title: CopyText
    let on: Bool
    let id: String
    var shape: VideoShape?
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let shape {
                    let r: CGFloat = shape == .landscape ? 16.0 / 9 : shape == .portrait ? 9.0 / 16 : 1
                    RoundedRectangle(cornerRadius: 1.5).strokeBorder(lineWidth: 1.2)
                        .frame(width: r >= 1 ? 12 : 12 * r, height: r >= 1 ? 12 / r : 12)
                        .frame(width: 12, height: 12)
                }
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title).typeStyle(.footnote).fixedSize()
            }
            .padding(.horizontal, Spacing.space2).padding(.vertical, 3)
            .foregroundStyle(on ? accentPreset.color : Color.textSecondary)
            .background(Capsule().fill(on ? accentPreset.color.opacity(0.12) : Color.clear))
            .overlay(Capsule().strokeBorder(on ? accentPreset.color.opacity(0.5) : Color.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
        .probeID(id)
    }
}
