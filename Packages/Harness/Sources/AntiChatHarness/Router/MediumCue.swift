// M2.T26 fix (R-238 AC1; P-shell-13): which MEDIUM a media request names. The embedding router decides well WHETHER
// a turn is media, but between picture and video it sometimes takes the wrong one ("create an animation of …",
// "Genera un clip de …" scored image_create; AT-238 run 2026-11-03: 7/100 cards named Photo for a video request).
// The medium is stated in the request's own words far more reliably than any embedding can tell, so once the router
// says "media", the words pick the pack: an explicit video word (video/clip/animation/… in the six languages) or,
// with an attached image, a motion phrase ("make this photo move", "bring it to life") → video; else an explicit
// picture word (picture/photo/drawing/logo/…) → photo; else no cue and the router's choice stands.
// This only chooses between two media tools the user asked for; it never blocks, rewrites or refuses (R-241).
// Checked against both labelled sets: 0 contradicting cues on media-100 (100 rows) and router-300 (300 rows).
import Foundation

public enum MediumCue {
    /// Video words: any one of these makes the request a video.
    static let videoWords: Set<String> = [
        "video", "videos", "vídeo", "vídeos", "vidéo", "vidéos", "videoclip", "videoclips", "clip", "clips", "clipe",
        "clipes", "filmpje", "filmpjes", "timelapse", "zeitraffer", "gif", "gifs",
        "animation", "animations", "animatie", "animaties", "animación", "animaciones", "animação", "animações",
        "animate", "animated", "animating", "animieren", "animiere", "animier", "animiert", "animeer", "animeren",
        "animez", "animer", "anima", "animar",
    ]
    /// "video game" / "video call" are not video requests.
    static let notVideoAfter: Set<String> = ["game", "games", "call", "calls"]
    /// French "anime" is the imperative only before a determiner ("Anime cette photo"); "style anime" is a picture.
    static let frenchDeterminers: Set<String> = [
        "cette", "ce", "cet", "ces", "la", "le", "les", "l", "mon", "ma", "mes", "ton", "ta", "tes", "notre", "nos",
        "votre", "vos",
    ]
    /// With an attached image, motion means "animate this picture".
    static let motionWords: Set<String> = [
        "move", "moves", "moving", "motion", "alive", "bewegen", "bewegt", "bewegung", "beweging", "lebendig", "levend",
        "bouger", "bouge", "bougent", "mouvement", "mover", "mueva", "mueve", "mueven", "muevan", "movimiento",
        "mexer", "mexa", "mexam", "mexe", "movimento",
    ]
    static let motionPhrases = ["to life", "cobre vida", "cobra vida", "ganhe vida", "ganha vida", "prenne vie",
                                "prend vie", "tot leven"]
    /// Picture words (and German compounds ending in -bild / -foto).
    static let pictureWords: Set<String> = [
        "picture", "pictures", "image", "images", "photo", "photos", "drawing", "draw", "illustration", "logo",
        "poster", "painting", "paint", "sketch", "wallpaper", "icon", "icons", "cover",
        "bild", "bilder", "foto", "fotos", "zeichnung", "zeichne", "plakat", "gemälde", "aquarell",
        "imagen", "imágenes", "dibujo", "dibuja", "ilustración", "logotipo", "cartel", "póster", "pintura", "acuarela",
        "icono", "portada", "imagem", "imagens", "desenho", "desenha", "ilustração", "cartaz", "aguarela", "aquarela",
        "ícone", "capa", "dessin", "dessine", "affiche", "peinture", "aquarelle", "icône", "couverture",
        "afbeelding", "plaatje", "tekening", "teken", "schilderij", "illustratie", "icoon",
    ]
    static let picturePhrases = ["fond d'écran", "fondo de pantalla", "papel de parede"]

    /// The medium the words name (nil = no cue; the router decides).
    public static func medium(_ text: String?, hasImage: Bool) -> MediaPack? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = lower.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        for (i, w) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            if videoWords.contains(w) {
                if w.hasPrefix("v"), w.count <= 5, let next, notVideoAfter.contains(next) { continue }
                return .video
            }
            if w == "anime", let next, frenchDeterminers.contains(next) { return .video }
        }
        if hasImage, words.contains(where: motionWords.contains) || motionPhrases.contains(where: lower.contains) {
            return .video
        }
        if words.contains(where: { pictureWords.contains($0) || $0.hasSuffix("bild") || $0.hasSuffix("foto") })
            || picturePhrases.contains(where: lower.contains)
        {
            return .photo
        }
        return nil
    }

    /// Art-style words that only a picture request uses (never a medium on their own: `medium` ignores them). They
    /// confirm a media route the embedding scored (`confirmsMedia`) for requests such as "a cozy cabin in snowy woods
    /// at dusk, watercolor" or "pixel art of a lighthouse" that name no picture word.
    static let styleWords: Set<String> = [
        "render", "rendering", "rendered", "watercolor", "watercolors", "watercolour", "watercolours", "pixel",
        "photorealistic", "photoreal", "fotorealistisch", "fotorrealista", "fotorrealismo", "photoréaliste", "fotorealista",
    ]
    /// "Mal mir …" (German "paint me …"): the imperative of "malen" is also the filler "mal", so only with "mir"/"uns".
    static let stylePhrases = ["mal mir", "male mir", "mal uns", "male uns"]

    /// Empty-reply fix (soak dry run 2, 2026-11-12): whether the request's own words (or its attached image) back a
    /// media route the embedding scored. The router's cosine scores alone put "Suggest a name for a small bakery that
    /// sells sourdough." and "Name three classic cocktails made with gin, one line each." confidently on image_create
    /// (next to the "logo for my coffee shop" prototype); every such turn was swallowed by the Photo install card or
    /// forced to call create_image, and the reply was an empty "done". A confident media route without this
    /// confirmation still exposes the media tool (the model can call it, which shows the card or makes the picture),
    /// but it neither replaces the reply with a card nor forces the tool. Over media-100 every row confirms; over
    /// router-300 129 of the 130 media rows do (the miss: "Ik wil een achtergrond voor mijn laptop …").
    public static func confirmsMedia(_ text: String?, hasImage: Bool, top: Route) -> Bool {
        guard top.isMedia else { return true }
        // An attached image backs an edit / animate-this route (that is what those routes mean).
        if hasImage, top == .imageEdit || top == .videoFromImage { return true }
        guard let text, !text.isEmpty else { return false }
        if medium(text, hasImage: hasImage) != nil { return true }
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = lower.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return words.contains(where: styleWords.contains) || stylePhrases.contains(where: lower.contains)
    }

    /// R66 F2: the media route the words alone name, for a turn the embedding could not score in time. Only the
    /// create routes and "animate this picture": with an attached image a picture word is as likely a question about
    /// it ("what is in this photo?") as an edit, so that stays with the scores. Style words ("watercolor of a fox")
    /// count as a picture request, as in `confirmsMedia`.
    public static func unscoredRoute(_ text: String?, hasImage: Bool) -> Route? {
        guard let text, !text.isEmpty else { return nil }
        switch medium(text, hasImage: hasImage) {
        case .video: return hasImage ? .videoFromImage : .videoCreate
        case .photo: return hasImage ? nil : .imageCreate
        case nil: return !hasImage && confirmsMedia(text, hasImage: false, top: .imageCreate) ? .imageCreate : nil
        }
    }

    /// The router's top route with its medium corrected by the words (only ever swaps one media route for the other).
    public static func resolve(_ top: Route?, text: String?, hasImage: Bool) -> Route? {
        guard let top, top.isMedia, let m = medium(text, hasImage: hasImage) else { return top }
        switch m {
        case .video: return top.isVideo ? top : (hasImage ? .videoFromImage : .videoCreate)
        case .photo: return top.isImage ? top : (hasImage ? .imageEdit : .imageCreate)
        }
    }
}
