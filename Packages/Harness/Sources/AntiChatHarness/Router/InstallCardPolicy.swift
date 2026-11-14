// M2.T24 (R-238; G-013, G-053; P-shell-13 / C-039): install cards that re-run the request. When a turn is a picture
// or a video (the pre-router's top intent, or a Create image / Create video chip) and that pack is not installed,
// the turn shows an InstallCard INSTEAD of sending the request to the chat model, so no text can claim a picture was
// made (AC1). An ineligible Mac gets the `install.unavailable` variant with the selector's reason and no button (AC3).
// A pack-missing media tool call from the model becomes the same card (tool result `pack_not_installed`), never a
// text claim (step 4). [Install] → the one disk rule → the pack queue; once verified, the original request re-runs
// in that chat (AC2, PendingRequestStore).
// Harness never sees Platform: the catalog/download/hardware facts come through `PackInstalling`, conformed in
// AntiChatUI and injected at the composition root (architecture §3 rule 1).
import AntiChatFoundation
import Foundation

/// The two packs an install card can offer.
public enum MediaPack: String, Codable, Sendable, CaseIterable, Hashable {
    case photo, video

    /// The pack a media tool needs (nil for every other tool).
    public static func forTool(_ name: String?) -> MediaPack? {
        switch name {
        case "create_image", "edit_image": .photo
        case "create_video": .video
        default: nil
        }
    }

    public static func forRoute(_ r: Route?) -> MediaPack? {
        guard let r else { return nil }
        return r.isImage ? .photo : r.isVideo ? .video : nil
    }

    /// The copy-deck name (`onb.pack.photo.name` "Photo" / `onb.pack.video.name` "Video").
    public var nameKey: String { "onb.pack.\(rawValue).name" }
    /// What the card promises to do once installed (`install.verb.image` "make your picture" / `.video`).
    public var verbKey: String { self == .photo ? "install.verb.image" : "install.verb.video" }
}

/// What this Mac can do about a pack right now (from the catalog selection, the store and the download queue).
public enum PackAvailability: Sendable, Hashable {
    case installed
    /// Not installed: `bytes` = Σ unique sha256 − already present (never 0), `minutes` at the measured/assumed rate.
    case installable(bytes: Int64, minutes: Int)
    /// Being downloaded / verified (`percent` 0…100).
    case installing(percent: Int)
    /// The selector refuses it on this Mac; `reason` is the dimmed line ("needs 24 GB memory").
    case unavailable(reason: String)
    /// This build does not ship the pack yet (ModelPack.shipped): nothing to install.
    case comingSoon
    /// M5.T08 (R-040 AC4, R-046): a video request on a Mac below the video memory floor: the explanation card
    /// (`video.notEligible` "Video needs {gb} GB memory. This Mac has {ram} GB." + `video.notEligible.images`).
    case videoNotEligible(gb: Int, ram: Int)
}

/// The outcome of [Install].
public enum PackInstallStart: Sendable, Hashable {
    case started
    /// NFR-D2: free < total + 10 GB; `gbNeeded` more is needed (`onb.diskShort`).
    case diskShort(gbNeeded: Int)
    case failed
}

/// The seam to the pack store (AntiChatUI conforms with Settings › Capabilities' pack model).
public protocol PackInstalling: Sendable {
    func availability(_ pack: MediaPack) async -> PackAvailability
    /// The disk rule, then enqueue the pack (the same path as Settings › Capabilities › Enable).
    func install(_ pack: MediaPack) async -> PackInstallStart
}

/// One card under a turn (the assistant message that would have answered).
public struct InstallCard: Sendable, Hashable, Codable {
    public enum State: Sendable, Hashable, Codable {
        case offered(bytes: Int64, minutes: Int)
        case downloading(percent: Int)
        case diskShort(gbNeeded: Int)
        /// Installed and verified: the original request is running again.
        case done
        case unavailable(reason: String)
        case failed
        /// The pack is not in this build yet (`install.comingSoon`, no button).
        case comingSoon
        /// M5.T08: the explanation card for a video request on an ineligible Mac. Plain text (no error styling), no
        /// button, no retry; the second line says images still work.
        case videoNotEligible(gb: Int, ram: Int)
    }

    public var pack: MediaPack
    public var state: State
    /// The user message to re-run once the pack is installed (nil for the unavailable variant).
    public var userMessageID: String?

    public init(pack: MediaPack, state: State, userMessageID: String? = nil) {
        self.pack = pack
        self.state = state
        self.userMessageID = userMessageID
    }

    /// The card's copy (every state resolves to a copy-deck key, H5).
    public var copyKey: String {
        switch state {
        case .offered: "install.card"
        case .downloading: "install.progress"
        case .diskShort: "onb.diskShort"
        case .done: "install.done"
        case .unavailable: "install.unavailable"
        case .failed: "install.failed"
        case .comingSoon: "install.comingSoon"
        case .videoNotEligible: "video.notEligible"
        }
    }

    /// [Install] / [Not now] are shown only while the card offers (or after a failure / a disk refusal: retry).
    public var hasButtons: Bool {
        switch state {
        case .offered, .diskShort, .failed: true
        case .downloading, .done, .unavailable, .comingSoon, .videoNotEligible: false
        }
    }
}

public enum InstallCardPolicy {
    /// The tool result a media tool returns while its pack is missing (step 4): the turn ends with the card.
    public static let packNotInstalled = #"{"error":"pack_not_installed"}"#

    /// The pack this turn needs: a forced media chip first, else the pre-router's confident top intent. nil = not media.
    public static func pack(for d: RouteDecision?) -> MediaPack? {
        guard let d else { return nil }
        // Only a confident top intent replaces the reply with a card (M2 review #13; R-241 "scores never block a
        // request"): a message that merely looks a bit like a picture request gets its text answer. Soak dry run 2:
        // nor does a confident route the request's words do not back ("Suggest a name for a small bakery …" scored
        // image_create and the card replaced the answer on every such turn; `MediumCue.confirmsMedia`): the model
        // answers, and its own media tool call still shows the card (step 4).
        return MediaPack.forTool(d.forcedTool)
            ?? (d.forcedTool == nil && d.confident && d.mediaConfirmed ? MediaPack.forRoute(d.top) : nil)
    }

    /// The card for a media turn whose pack is not installed (nil = send the request as usual).
    public static func card(_ pack: MediaPack, availability: PackAvailability, userMessageID: String?) -> InstallCard? {
        switch availability {
        case .installed: nil
        case .installable(let bytes, let minutes):
            InstallCard(pack: pack, state: .offered(bytes: max(bytes, 1), minutes: max(minutes, 1)), userMessageID: userMessageID)
        case .installing(let percent): InstallCard(pack: pack, state: .downloading(percent: percent), userMessageID: userMessageID)
        case .unavailable(let reason): InstallCard(pack: pack, state: .unavailable(reason: reason))
        case .comingSoon: InstallCard(pack: pack, state: .comingSoon)
        case .videoNotEligible(let gb, let ram): InstallCard(pack: pack, state: .videoNotEligible(gb: gb, ram: ram))
        }
    }
}
