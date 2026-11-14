// M5.T10 step 2 (R-040 AC1, R-046): `+ → Create video` (`add.video`). The row itself is SlashCommandRegistry's
// `video` action (sticky chip `video` → ChipOverride forces `create_video` on every turn while it is present; dimmed
// with VideoEligibility's reason on an ineligible Mac, M5.T08 — never hidden). This file holds what the rest of the
// window derives from the same row: whether Animate (image cards, image tiles) may be offered right now.
import AntiChatHarness
import Foundation

extension ComposerMenuContext {
    /// Video can start from this window now: the Video pack is installed and on, and this Mac is eligible (the
    /// Create video row would be enabled). Animate is shown only then; an ineligible Mac explains itself through the
    /// dimmed + menu row and the explanation card instead.
    public var videoAvailable: Bool {
        installedPacks.contains(VideoRoute.chipID) && !disabledPacks.contains(VideoRoute.chipID)
            && ineligiblePacks[VideoRoute.chipID] == nil
    }
}
