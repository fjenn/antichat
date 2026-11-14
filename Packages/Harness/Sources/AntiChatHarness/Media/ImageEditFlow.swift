// M4.T13 (R-033 AC1/AC2; G-041, G-042; P-media-07, P-media-08): edit a picture by text.
//   * Entry points: the result card's Edit and the viewer's `editor.describe` field (the UI names the picture with
//     `TurnController.setActiveImageNextTurn` and forces `edit_image` with the `tool:edit_image` chip), or a plain chat
//     message about the last picture ("make the cake pink"). Either way the CHAT MODEL writes the `edit_image` call:
//     the turn carries one context line naming the picture in focus and its id, so the model's `source_image_id` is
//     the real id (an artifact id = its newest version, a version id = that exact version, an attachment id = an
//     uploaded picture). Uploaded inputs are never checked (D-005); the RESULT goes through the runner and the gate
//     like any Photo output (R-033 AC1).
//   * Lineage: the result is a new `artifact_version` of the SOURCE artifact with parent = the source version and the
//     call's operation (`edit`, `inpaint`, …), so v1 → edit → v2 and v1 → second edit → v3 (a sibling of v2, parent
//     v1); nothing is deleted (AC2). An uploaded source has no version: its edit starts a new artifact (v1, parent
//     NULL). The PNG metadata's `parent` / `operation` (MediaProvenanceWriter) match the row.
//   * Request: an instruction edit hands the source to sd-server as a reference image (`ref_images`: FLUX.2-klein
//     multi-reference edit; Qwen-Image-Edit via its `--llm_vision` mmproj), at the source's aspect with the speed
//     class's pixel count ("same resolution", NFR-P4); an inpaint sends `init_image` + `mask_image`.
import AntiChatEngineProtocol
import AntiChatStorage
import AntiChatTools
import CoreGraphics
import Foundation
import GRDB
import ImageIO

public enum ImageEditFlow {
    /// The picture a turn talks about.
    public struct ActiveImage: Sendable, Equatable {
        public enum Origin: String, Sendable { case generated, uploaded }
        /// What the model passes as `source_image_id` (artifact, version or attachment id).
        public var id: String
        public var origin: Origin
        /// 1-based version shown / total versions of the artifact (generated pictures only).
        public var version: Int?
        public var versions: Int?

        public init(id: String, origin: Origin, version: Int? = nil, versions: Int? = nil) {
            self.id = id; self.origin = origin; self.version = version; self.versions = versions
        }
    }

    /// The picture in focus for a turn: the one the UI named (card Edit / viewer field), else the newest image the
    /// user attached to this message, else the chat's newest picture (the last generated or edited one). nil = none.
    public static func activeImage(chatID: String, userMessageID: String?, explicit: String?, db: Database) throws -> ActiveImage? {
        if let explicit, let a = try describe(explicit, chatID: chatID, db: db) { return a }
        if let userMessageID, let img = try ImageContext.images(messageID: userMessageID, db: db).last {
            return ActiveImage(id: img.attachmentID, origin: .uploaded)
        }
        let newest = try Row.fetchOne(db, sql: """
            SELECT v.artifact_id FROM artifact_version v JOIN artifact a ON a.id = v.artifact_id
            WHERE a.chat_id = ? AND a.kind = 'image' ORDER BY v.created_at DESC, v.n DESC LIMIT 1
            """, arguments: [chatID])
        guard let artifactID: String = newest?["artifact_id"] else { return nil }
        return try describe(artifactID, chatID: chatID, db: db)
    }

    /// `id` as an active image (nil = not a picture of this chat).
    static func describe(_ id: String, chatID: String, db: Database) throws -> ActiveImage? {
        if let a = try AttachmentRecord.fetchOne(db, key: id) {
            // M4 review: an image attached to a sent message of this chat only.
            guard ImageContext.isImage(a), let mid = a.messageID, try MessageRecord.fetchOne(db, key: mid)?.chatID == chatID else { return nil }
            return ActiveImage(id: a.id, origin: .uploaded)
        }
        let version = try ArtifactVersionRecord.fetchOne(db, key: id)
            ?? ArtifactVersionRecord.filter(Column("artifact_id") == id).order(Column("n").desc).fetchOne(db)
        guard let v = version, let art = try ArtifactRecord.fetchOne(db, key: v.artifactID), art.chatID == chatID else { return nil }
        let total = try ArtifactVersionRecord.filter(Column("artifact_id") == v.artifactID).fetchCount(db)
        // The newest version is named by its artifact id (what create_image returned); an older one by its version id.
        let isNewest = v.n == (try Int.fetchOne(db, sql: "SELECT MAX(n) FROM artifact_version WHERE artifact_id = ?",
                                                 arguments: [v.artifactID]) ?? v.n)
        return ActiveImage(id: isNewest ? v.artifactID : v.id, origin: .generated, version: v.n, versions: total)
    }

    /// The turn's context line for the model (English, like every harness instruction).
    public static func contextLine(_ a: ActiveImage) -> String {
        let what: String
        switch a.origin {
        case .uploaded: what = "a picture the user uploaded"
        case .generated:
            if let n = a.version, let t = a.versions, t > 1 { what = "a picture made in this chat (version \(n) of \(t))" }
            else { what = "a picture made in this chat" }
        }
        return "Picture in focus: \(what), image_id \"\(a.id)\". To change it, call edit_image with source_image_id \"\(a.id)\"."
    }

    // MARK: - Source → request / lineage

    /// Resolves a `source_image_id` / `mask_id` in the chat's store (the tool call's `ToolCallStore.database`).
    public static func resolve(_ id: String, database: AppDatabase?, chatID: String?) -> ArtifactStore.ImageRef? {
        guard let database else { return nil }
        return FileOutTools.Stores.shared.store(for: database).resolveImage(ref: id, chatID: chatID)
    }

    /// Where the result is stored: a version of the source artifact (parent = the source version), or a new artifact
    /// for an uploaded source.
    public static func saveTarget(_ source: ArtifactStore.ImageRef?) -> (revises: String?, parent: String?) {
        guard let source, let artifact = source.artifactID else { return (nil, nil) }
        return (artifact, source.versionID)
    }

    /// Pixel size of a picture file (nil = unreadable).
    public static func pixelSize(_ path: String) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    /// The edit's size: the source's aspect at the speed class's pixel count (multiples of 64), so an edit runs at the
    /// same resolution as a generation (NFR-P4 compares the two).
    public static func resolution(source: (width: Int, height: Int), speed: ImageSpeedClass, stepDown: Bool) -> (width: Int, height: Int) {
        let side = stepDown ? (speed.baseSide > 768 ? 768 : 640) : speed.baseSide
        let area = Double(side * side), ratio = Double(source.width) / Double(source.height)
        func r64(_ x: Double) -> Int { max(64, Int((x / 64).rounded()) * 64) }
        return (r64((area * ratio).squareRoot()), r64((area / ratio).squareRoot()))
    }

    /// M4.md "Known failure modes" (lead decision 2026-11-08, AT-NFR-P4): a FLUX.2-klein instruction edit runs as
    /// sd-server img2img — the source as `init_image` at strength 0.6 (fewer denoising steps, no reference tokens) —
    /// instead of a multi-reference edit (2× the tokens per step: P4 1.93× at T1).
    public static let kleinEditStrength: Float = 0.6

    /// The img2img prompt of a klein instruction edit: the picture's scene (the prompt of the version that generated
    /// it, found up the parent chain) followed by the change. img2img re-draws the whole picture from its prompt, so
    /// the bare instruction ("make the sky purple") at strength 0.6 dropped the subject (the lighthouse) — seen in the
    /// M4.T16 real-model journey 5. Unknown scene (an uploaded source) ⇒ the instruction alone.
    public static func img2imgPrompt(instruction: String, sourceVersionID: String?, database: AppDatabase?) -> String {
        guard let database, var id = sourceVersionID else { return instruction }
        let scene: String? = try? database.read { db -> String? in
            for _ in 0..<64 {  // a deep edit chain; bounded against a corrupt cycle
                guard let v = try ArtifactVersionRecord.fetchOne(db, key: id) else { return nil }
                if v.operation == nil || v.operation == ArtifactOperation.generate.rawValue || v.parentVersionID == nil {
                    let o = v.specJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
                    return o?["prompt"] as? String
                }
                id = v.parentVersionID!
            }
            return nil
        }
        guard let scene = scene?.trimmingCharacters(in: .whitespacesAndNewlines), !scene.isEmpty,
              scene.caseInsensitiveCompare(instruction) != .orderedSame else { return instruction }
        let head = scene.hasSuffix(".") ? scene : scene + "."
        return "\(head) \(instruction)"
    }

    /// The model key's instruction-edit path: img2img for klein (and any non-Qwen create model), reference picture for
    /// Qwen-Image-Edit (its vision encoder reads the source).
    public static func usesImg2Img(modelKey: String) -> Bool { !modelKey.hasPrefix("img-edit") }

    /// Shapes `req` for the call's mode: an instruction edit (`edit`) passes the source as a reference picture
    /// (img-edit) or as the img2img init image at `kleinEditStrength` (klein); an inpaint / outpaint passes it as the
    /// init image with the mask.
    /// A masked edit (`mask_id`, any mode) is composited back onto the source through the feathered mask in the helper
    /// before the gate (MaskCompositor): outside the mask the picture is unchanged (M4 review round 2).
    public static func apply(mode: String, source: String, mask: String?, to req: inout ImageRequest) {
        if mode == "edit" && usesImg2Img(modelKey: req.model.key) {
            req.initImagePath = source
            req.strength = kleinEditStrength
            req.refImagePaths = nil
            req.maskImagePath = mask
        } else if mode == "edit" {
            req.refImagePaths = [source]
            req.initImagePath = nil
            req.maskImagePath = mask
        } else {
            req.initImagePath = source
            req.maskImagePath = mask
            req.refImagePaths = nil
        }
    }
}
