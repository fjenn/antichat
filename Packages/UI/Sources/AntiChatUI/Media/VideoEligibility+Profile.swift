// M5.T08 step 1 (R-046 AC1): the Platform facts behind `VideoEligibility` (Harness never sees Platform). One mapping
// for the onboarding Video card, Settings → Capabilities' Video row (both via OnboardingModel.isEligible / reason),
// the + menu's Create video row (ComposerMenuContext.ineligiblePacks) and the explanation card for a video request on
// an ineligible Mac (CapabilitiesPackInstaller → `video.notEligible` + `video.notEligible.images`).
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import Foundation

extension VideoEligibility.Input {
    /// - Parameters: `catalog` gives the chat model's resident size on T3+ (chat stays loaded beside video there; T2
    ///   unloads it first, cross-task contract 2). `runtimeInstalled` only changes the offer (install card), never dims.
    public init(profile: HardwareProfile, selection: Selection, catalog: ModelCatalog? = nil, runtimeInstalled: Bool = true) {
        let slot = selection.slot(.video, .normal, role: "video")
        var resident = 0.0
        if profile.tier > .T2, let id = selection.slot(.chat, .normal, role: "chat")?.modelID,
           let m = catalog?.models[id] {
            resident = FitRule.resident(m, ctx: selection.slot(.chat, .normal, role: "chat")?.ctx ?? 0)
        }
        self.init(tier: profile.tier.rawValue, speedClass: profile.speedClass.rawValue, ramGB: profile.ramGB,
                  budgetGB: profile.B, videoModelID: slot?.modelID, catalogReason: slot?.reason, residentGB: resident,
                  runtimeInstalled: runtimeInstalled)
    }
}

extension VideoEligibility.Reason {
    /// The dimmed line ("Needs 24 GB memory" / "Too slow on this Mac's chip").
    public var copyText: CopyText { CopyText(CopyKey(copyKey), copyArgs) }
}

extension VideoEligibility {
    public static func evaluate(profile: HardwareProfile, selection: Selection, catalog: ModelCatalog? = nil) -> Result {
        evaluate(Input(profile: profile, selection: selection, catalog: catalog))
    }
}
