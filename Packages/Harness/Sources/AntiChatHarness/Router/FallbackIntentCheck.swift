// M2.T23 step 3 (R-235 AC3): when the pre-router is confident (`score ≥ high`) that the turn asks for a picture or a
// video and the model answered without calling the media tool, the turn re-asks ONCE with `tool_choice` = that tool.
// If that still brings no media, the reply gets a MediaOfferChip ("Create this as an image?" / "…as a video?");
// clicking it re-runs the request with the chip forced. Never a second re-ask. `FeatureFlag.fallbackIntentCheck` off
// disables the re-ask (the chip still shows). The constrained-JSON intent check (P-shell-13) is NOT built in v1
// (D-026): it stays the documented fallback if the R-235 AC4 bar is missed (M2.md M2.T23 "Known failure modes").
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public enum FallbackIntentCheck {
    public enum Action: Sendable, Hashable {
        /// Re-ask once with `tool_choice` = this tool.
        case reask(tool: String)
        /// Attach the offer chip under the reply.
        case offer(MediaOfferChip)
    }

    /// The media tool a confident decision expects (nil: not media, not confident, or the tool is not offered).
    public static func expectedTool(_ d: RouteDecision?) -> String? {
        guard let d, d.confident, d.forcedTool == nil, let top = d.top, top.isMedia, let tool = top.tools.first else { return nil }
        return d.toolsToExpose.contains { $0.name == tool } ? tool : nil
    }

    /// What to do when a turn ends. `calledTools` = every tool the turn's steps called; `reasked` = the re-ask ran.
    public static func action(decision: RouteDecision?, calledTools: Set<String>, reasked: Bool,
                              enabled: Bool = FeatureFlag.fallbackIntentCheck.isEnabled()) -> Action? {
        // "No media in the reply": a call to either media tool (even the other one) ends the check.
        guard let tool = expectedTool(decision), calledTools.isDisjoint(with: ["create_image", "edit_image", "create_video"]),
              let top = decision?.top else { return nil }
        // Soak dry run 2: a route the request's words do not back (MediumCue.confirmsMedia) is never forced — the
        // text answer stands, with the offer chip under it.
        if enabled, !reasked, decision?.mediaConfirmed ?? true { return .reask(tool: tool) }
        return .offer(MediaOfferChip(route: top))
    }
}

/// The chip under a reply that should have been media (R-235 AC3 text; S-08 variant).
public struct MediaOfferChip: Sendable, Hashable, Codable {
    public var kind: Kind
    public enum Kind: String, Sendable, Hashable, Codable { case image, video }

    public init(route: Route) { kind = route.isVideo ? .video : .image }
    public init(kind: Kind) { self.kind = kind }

    /// Copy key: `router.offerImage` = "Create this as an image?", `router.offerVideo` = "Create this as a video?".
    public var copyKey: String { kind == .video ? "router.offerVideo" : "router.offerImage" }
    /// The composer chip a click forces (ChipOverride: `image` → create_image, `video` → create_video).
    public var chipID: String { kind == .video ? "video" : "image" }
}
