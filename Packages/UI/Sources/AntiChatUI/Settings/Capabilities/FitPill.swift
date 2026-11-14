// M2.T07 (R-222 AC2; S-21 Capabilities › Advanced): the FitRule class of a model on this Mac, as a small pill —
// Fits (comfortable, ≤ 0.85 B), Tight (≤ B), Too large (> B). Text + shape carry the state, colour only reinforces it.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct FitPill: View {
    let fit: FitClass
    /// Q-015 r5: false inside a Picker option — the selected option is drawn as the picker's own label, and the pill's
    /// id then replaced the picker's (`override.chat.normal` read `fitPill.fits` once a model was picked).
    var identified = true

    var body: some View {
        if identified { pill.accessibilityIdentifier("fitPill.\(fit.rawValue)") } else { pill }
    }

    private var pill: some View {
        Text(CopyKey(Self.key(fit)))
            .typeStyle(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }

    static func key(_ fit: FitClass) -> String {
        switch fit {
        case .fits: "set.cap.fit.fits"
        case .tight: "set.cap.fit.tight"
        case .tooLarge: "set.cap.fit.tooLarge"
        }
    }

    private var tint: Color {
        switch fit {
        case .fits: Color.success
        case .tight: Color.warning
        case .tooLarge: Color.danger
        }
    }
}
