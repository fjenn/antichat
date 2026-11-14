// M5.T10 step 1 (R-040 AC1, R-043 AC1; G-045; P-shell-13 reused): what a video turn is — text-to-video or
// image-to-video, from which picture, and how explicitly the user asked (the plan card's countdown rule, R-290 AC2).
// The embedding router (PreRouter: route-prototypes.json `video_create` / `video_from_image` in en/de/es/fr/nl/pt,
// thresholds fitted by tools/router/fit.py on the M2.T23 calibration split of router-300 only; MediumCue picks video
// over picture from the request's own words) decides THAT a turn is video; this type decides the rest:
//   * source picture (I2V) — Animate's picture, else the `create_video` call's `source_image_id`, else an image
//     attached to this turn (R-040 AC1: "a video request on an attached image starts image-to-video"), else "the last
//     image" when the words refer to it ("animate the last picture", "la dernière image", …), else none (T2V);
//   * intent — Animate → `animate`; the `+ → Create video` chip → `createVideoChip`; a request that names a video
//     (router `video_*` or a video word) → `namedVideo`; anything else that reached `create_video` → `inferred`
//     (no countdown).
// It never blocks, rewrites or refuses a request (R-241); it only picks between the two video modes the user asked for.
import Foundation

public enum VideoRoute {
    /// The composer chip id of `+ → Create video` (ChipOverride: `video` → `create_video`).
    public static let chipID = "video"
    /// A one-shot chip Animate adds to its request: `animate:<image ref>` (an artifact or attachment id).
    public static let animatePrefix = "animate:"

    public static func animateChip(_ imageRef: String) -> String { animatePrefix + imageRef }

    /// Animate's picture, if this turn came from an Animate action.
    public static func animateSource(chips: [String]) -> String? {
        chips.first { $0.hasPrefix(animatePrefix) }.map { String($0.dropFirst(animatePrefix.count)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What the turn knows when `create_video` runs.
    public struct Facts: Sendable, Equatable {
        public var chips: [String]
        /// The pre-router's top route (nil = chat / unscored).
        public var routeTop: Route?
        public var userText: String?
        /// Image attachments of this turn's user message (attach order).
        public var attachedImageIDs: [String]
        /// The chat's newest picture (artifact or attachment), for "the last image".
        public var lastImageID: String?

        public init(chips: [String] = [], routeTop: Route? = nil, userText: String? = nil, attachedImageIDs: [String] = [],
                    lastImageID: String? = nil) {
            self.chips = chips; self.routeTop = routeTop; self.userText = userText
            self.attachedImageIDs = attachedImageIDs; self.lastImageID = lastImageID
        }
    }

    public struct Choice: Sendable, Equatable {
        public var mode: VideoMode
        public var intent: VideoPlanPolicy.Intent
        public var sourceImageID: String?
    }

    /// The video turn's mode, source and intent. `callSourceImageID` = the model's `source_image_id`, if any.
    public static func choose(_ f: Facts, callSourceImageID: String? = nil) -> Choice {
        let source = animateSource(chips: f.chips)
            ?? callSourceImageID
            ?? f.attachedImageIDs.last
            ?? (refersToLastImage(f.userText) ? f.lastImageID : nil)
        return Choice(mode: source == nil ? .t2v : .i2v, intent: intent(f), sourceImageID: source)
    }

    public static func intent(_ f: Facts) -> VideoPlanPolicy.Intent {
        if animateSource(chips: f.chips) != nil { return .animate }
        if f.chips.contains(chipID) { return .createVideoChip }
        if f.routeTop?.isVideo == true || MediumCue.medium(f.userText, hasImage: !f.attachedImageIDs.isEmpty) == .video {
            return .namedVideo
        }
        return .inferred
    }

    // MARK: "the last image"

    /// Phrases naming the previous picture, in the six router languages (lowercased, apostrophes normalised).
    static let lastImagePhrases: [String] = [
        // en
        "last image", "last picture", "last photo", "previous image", "previous picture", "previous photo",
        "that image", "that picture", "that photo", "the image above", "the picture above", "the photo above",
        "image you just made", "picture you just made", "image you made", "picture you made",
        // de
        "letzte bild", "letzten bild", "letztes bild", "vorherige bild", "vorherigen bild", "das bild oben", "dieses bild",
        "letzte foto", "letzten foto", "letztes foto",
        // es
        "última imagen", "ultima imagen", "imagen anterior", "esa imagen", "la imagen de arriba", "última foto", "ultima foto",
        "foto anterior", "esa foto",
        // fr
        "dernière image", "derniere image", "image précédente", "image precedente", "cette image", "l'image ci-dessus",
        "dernière photo", "derniere photo", "photo précédente",
        // nl
        "laatste afbeelding", "vorige afbeelding", "die afbeelding", "deze afbeelding", "laatste foto", "vorige foto",
        "laatste plaatje", "vorige plaatje",
        // pt
        "última imagem", "ultima imagem", "imagem anterior", "essa imagem", "esta imagem", "a imagem acima",
        "última foto", "foto anterior", "essa foto",
    ]

    /// True when the words point at the chat's previous picture ("animate the last image").
    public static func refersToLastImage(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return lastImagePhrases.contains { lower.contains($0) }
    }
}
