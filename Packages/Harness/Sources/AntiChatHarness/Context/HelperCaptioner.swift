// M6.T06 step 1 (R-237 AC1; P-files-tools-04): the text-only fallback's caption. When the chat model cannot see, the
// starter VLM (`chat-0.8b` with its vision tower, the helper that stays installed, R-298) describes the image once:
// "Describe this image in detail for someone who can't see it. Include any visible text verbatim." (≤ 256 tokens,
// temperature 0, no thinking). The caption is stored on the attachment (`caption_text`) and reused by every later
// turn and by compaction (AC2): the helper never runs twice for one image. Lives in Harness (it needs the engine;
// Knowledge imports only Storage + the vendored code, contract 1).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Synchronization

public struct HelperCaptioner: Sendable {
    public static let prompt = "Describe this image in detail for someone who can't see it. Include any visible text verbatim."
    public static let maxTokens = 256

    public let engine: any EngineService
    public let slot: ModelSlot
    public let preparer: ImageInputPreparer

    public init(engine: any EngineService, slot: ModelSlot, preparer: ImageInputPreparer) {
        self.engine = engine
        self.slot = slot
        self.preparer = preparer
    }

    /// One caption (nil when the helper fails or says nothing).
    public func caption(_ imagePath: String, sha256: String? = nil) async -> String? {
        guard let png = try? preparer.prepare(URL(fileURLWithPath: imagePath), sha256: sha256) else { return nil }
        let req = ChatRequest(sessionID: UUID(), modelSlot: slot,
                              messages: [.message(ChatMessage(role: .user, content: Self.prompt, imagePaths: [png.path]))],
                              reasoning: .off, sampling: Sampling(temperature: 0, maxTokens: Self.maxTokens))
        var text = ""
        do {
            for try await e in engine.chat(req) {
                switch e {
                case .textDelta(let d): text += d
                case .error(let err):
                    AppLog.log(.harness, .notice, "helper caption failed: \(err.fullCode)")
                    return nil
                default: break
                }
            }
        } catch {
            return nil
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Captions the images among `attachmentIDs` that have none yet; returns how many helper calls ran.
    @discardableResult
    public func captionMissing(_ attachmentIDs: [String], database: AppDatabase) async -> Int {
        guard !attachmentIDs.isEmpty, let rows = try? database.read({ db in
            try AttachmentRecord.filter(attachmentIDs.contains(Column("id"))).fetchAll(db)
                .filter { ImageContext.isImage($0) && ($0.captionText ?? "").isEmpty }
                .compactMap { a in try FileBlobRecord.fetchOne(db, key: a.blobID).map { (a.id, $0.path, $0.sha256) } }
        }) else { return 0 }
        var calls = 0
        for (id, path, sha) in rows {
            calls += 1
            guard let caption = await caption(path, sha256: sha) else { continue }
            _ = try? database.write { db in
                try db.execute(sql: "UPDATE attachment SET caption_text = ? WHERE id = ?", arguments: [caption, id])
            }
        }
        return calls
    }
}
