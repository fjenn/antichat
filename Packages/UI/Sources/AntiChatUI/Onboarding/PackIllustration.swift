// M10 visual QA (S-02/S-04; tokens.md §6 "Pack icons"): the pack art — the owner's own isometric 3D icons (a pair of
// speech bubbles, a studio mic, two photo prints, a camcorder and the Evil devil; Resources/PackIcons.xcassets, 512 px
// + @2x, provenance in Resources/Onboarding/SOURCES.md). One soft drop shadow so they sit on the glass cards (step 2),
// the light panel (step 4) and the Settings list alike. Decorative: hidden from VoiceOver (the card / row names the pack).
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct PackIllustration: View {
    /// nil = the Evil row.
    let pack: ModelPack?
    var size: CGFloat = 48

    /// The asset-catalog name of a pack's icon (nil = Evil).
    static func assetName(_ pack: ModelPack?) -> String {
        switch pack {
        case .chat: "pack-chat"
        case .voice: "pack-voice"
        case .photo: "pack-images"
        case .video: "pack-video"
        case nil: "pack-evil"
        }
    }

    var body: some View {
        Image(Self.assetName(pack), bundle: .module)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.28), radius: size * 0.06, x: 0, y: size * 0.04)
            .accessibilityHidden(true)
    }
}
