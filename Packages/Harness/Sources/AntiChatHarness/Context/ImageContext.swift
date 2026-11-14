// M6.T05 step 3 (R-021 AC1; architecture §4.3): images of a turn. A user message's image attachments ride on its
// prompt message as file paths; per turn the chat slot decides: a model that can see (`VisionRouting.visionSlot`: an
// MLX model with a vision tower loads through the VLM factory as `<key>+vision`; a GGUF model with its mmproj) gets
// the images prepared by ImageInputPreparer (long side ≤ 1024, PNG in the transfer dir, paths only over XPC);
// otherwise they are stripped and the reply's card says `img.needsLargerModel` (M6.T06 adds the helper caption path).
// OCR text (M6.T04) goes in either way. Incognito: the transfer copy lives in a temp dir, never the caches folder.
import AntiChatFoundation
import AntiChatEngineProtocol
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import UniformTypeIdentifiers

public struct VisionRouting: Sendable {
    /// The slot that sees images for a chat slot (nil = the model is text-only).
    public var visionSlot: @Sendable (ModelSlot) -> ModelSlot?
    /// Where prepared images go (`incognito` → a temp dir).
    public var preparer: @Sendable (_ incognito: Bool) -> ImageInputPreparer
    /// M6.T06: the helper VLM that captions images for a text-only model (the starter with its vision tower; nil =
    /// none installed → `img.needsLargerModel`).
    public var helperSlot: @Sendable () -> ModelSlot?
    /// M6.T06 step 4: the helper may run now (false on T0, where it would not fit next to the chat model: OCR only).
    public var captionsAllowed: @Sendable () -> Bool

    public init(visionSlot: @escaping @Sendable (ModelSlot) -> ModelSlot? = VisionRouting.defaultVisionSlot,
                preparer: @escaping @Sendable (_ incognito: Bool) -> ImageInputPreparer = VisionRouting.defaultPreparer,
                helperSlot: @escaping @Sendable () -> ModelSlot? = { nil },
                captionsAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.visionSlot = visionSlot
        self.preparer = preparer
        self.helperSlot = helperSlot
        self.captionsAllowed = captionsAllowed
    }

    /// A slot already loaded with vision; else an MLX model whose `config.json` has a `vision_config` (its VLM variant
    /// `<key>+vision`); else none (a GGUF model sees only with its mmproj, which sets `vision` on the slot).
    public static let defaultVisionSlot: @Sendable (ModelSlot) -> ModelSlot? = { s in
        if s.vision { return s }
        guard s.engine == .mlx, hasVisionTower(s.path) else { return nil }
        var v = s
        v.vision = true
        v.key = s.key + "+vision"
        return v
    }

    public static let defaultPreparer: @Sendable (Bool) -> ImageInputPreparer = { incognito in
        incognito ? ImageInputPreparer(directory: incognitoXfer) : ImageInputPreparer()
    }

    /// This process's incognito image-input dir (owned, so another process's launch sweep keeps it while we run; it
    /// used to be one fixed `AntiChat-incognito-xfer` shared by every AntiChat process).
    static let incognitoXfer: URL = IncognitoTemp.make("xfer-\(UUID().uuidString)")

    public static func hasVisionTower(_ modelDir: String) -> Bool {
        guard !modelDir.isEmpty,
              let data = FileManager.default.contents(atPath: (modelDir as NSString).appendingPathComponent("config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["vision_config"] != nil
    }
}

public enum ImageContext {
    public struct Image: Sendable, Equatable {
        public var attachmentID: String
        public var name: String
        public var path: String
        public var sha256: String
    }

    public static func isImage(_ a: AttachmentRecord) -> Bool { UTType(a.uti)?.conforms(to: .image) == true }

    /// The image attachments of a message, in attach order.
    public static func images(messageID: String, db: Database) throws -> [Image] {
        try AttachmentRecord.filter(Column("message_id") == messageID).order(Column("created_at")).fetchAll(db)
            .filter(isImage)
            .compactMap { a in
                try FileBlobRecord.fetchOne(db, key: a.blobID).map {
                    Image(attachmentID: a.id, name: a.displayName, path: $0.path, sha256: $0.sha256)
                }
            }
    }

    /// The prompt with every image path replaced by its prepared copy (an image that cannot be read is dropped).
    public static func prepared(_ prompt: [ChatMessage], with preparer: ImageInputPreparer) -> [ChatMessage] {
        prompt.map { m in
            guard !m.imagePaths.isEmpty else { return m }
            var c = m
            c.imagePaths = m.imagePaths.compactMap { p in
                let sha = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                return try? preparer.prepare(URL(fileURLWithPath: p), sha256: sha.count == 64 ? sha : nil).path
            }
            return c
        }
    }

    /// The prompt without images (a text-only model).
    public static func stripped(_ prompt: [ChatMessage]) -> [ChatMessage] {
        prompt.map { m in var c = m; c.imagePaths = []; return c }
    }
}
