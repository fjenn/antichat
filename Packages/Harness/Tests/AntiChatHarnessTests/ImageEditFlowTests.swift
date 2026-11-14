// AT-033 AC2 (R-033; M4.T13 step 5): edit by text keeps every version. Through the real tool path (ImageTools.run →
// MediaJobQueue → a fake helper transport → ArtifactStore): v1 (create) → edit → v2 (parent v1, operation `edit`);
// v1 → a second edit → v3 (parent v1: a sibling of v2); nothing is deleted. The request hands the source to sd-server
// as a reference picture at the source's aspect; an uploaded source starts its own artifact; an inpaint sends init +
// mask; the PNG's provenance `parent` / `operation` match the row; the turn names the picture in focus for the model.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ImageEditFlowTests {
    /// A content-free solid PNG of `w`×`h`.
    static func png(_ w: Int, _ h: Int, gray: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        return out as Data
    }

    final class Fixture: @unchecked Sendable {
        let db: AppDatabase
        let chat = ChatRecord(mode: .normal)
        let transport = FakeMediaTransport()
        let queue: MediaJobQueue
        let dir: URL
        var gray: CGFloat = 0.1

        init() throws {
            db = try AppDatabase.inMemory()
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-flow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            queue = MediaJobQueue(database: db, transport: transport, xferRoot: dir, safety: { nil })
            try db.write { try chat.insert($0) }
        }

        /// Runs one tool call; the fake helper answers with a fresh result PNG of `size` (what the gate would allow).
        func call(_ tool: String, _ args: String, size: (Int, Int) = (96, 64)) async throws -> (ImageTurnPolicy.Outcome, MediaJobSubmit) {
            let before = transport.submittedJobs.count
            let db = db, queue = queue, chat = chat.id
            let task = Task {
                try await ToolCallStore.$database.withValue(db) {
                    try await ImageTools.run(tool, args, queue: queue, photo: FakePhoto(), chatID: chat)
                }
            }
            for _ in 0..<500 where transport.submittedJobs.count == before { try await Task.sleep(for: .milliseconds(5)) }
            guard transport.submittedJobs.count > before else {
                return (try await task.value, MediaJobSubmit(job: "-", image: ImageRequest(model: FakePhoto.set, prompt: "", width: 0,
                                                                                           height: 0, seed: 0, outputPath: ""), safety: nil))
            }
            let sub = transport.submitted[before]
            gray += 0.2
            let out = dir.appendingPathComponent("\(sub.job).png")
            try ImageEditFlowTests.png(size.0, size.1, gray: gray).write(to: out)
            transport.end(sub.job, .jobResult(job: sub.job, path: out.path, metadata: [:]))
            return (try await task.value, sub)
        }

        func versions(_ artifact: String) throws -> [ArtifactVersionRecord] {
            try db.read { db in try ArtifactVersionRecord.filter(Column("artifact_id") == artifact).order(Column("n")).fetchAll(db) }
        }

        func path(_ v: ArtifactVersionRecord) throws -> String {
            try db.read { db in try FileBlobRecord.fetchOne(db, key: v.blobID)!.path }
        }
    }

    static func id(_ o: ImageTurnPolicy.Outcome) -> String {
        if case .done(let id, _, _, _) = o { return id }
        Issue.record("not done: \(o)")
        return ""
    }

    @Test func versionTreeKeepsEverything() async throws {
        let f = try Fixture()
        let (created, _) = try await f.call("create_image", #"{"prompt":"a cake on a table","seed":1}"#)
        let artifact = Self.id(created)
        let v1 = try #require(try f.versions(artifact).first)
        #expect(v1.n == 1 && v1.operation == "generate" && v1.parentVersionID == nil)

        // v1 → edit → v2 (the source is named by its artifact id = the newest version).
        let (e1, sub1) = try await f.call("edit_image", #"{"prompt":"make the cake pink","source_image_id":"\#(artifact)"}"#)
        #expect(sub1.kind == .edit)
        // klein (the quick edit model) runs the instruction edit as img2img at strength 0.6 (P4 fallback).
        #expect(sub1.image.initImagePath == (try f.path(v1)) && sub1.image.strength == 0.6)
        #expect(sub1.image.refImagePaths == nil && sub1.image.maskImagePath == nil)
        // img2img re-draws from its prompt: the scene comes along with the change (M4.T16: the bare instruction lost
        // the subject in the real-model run).
        #expect(sub1.image.prompt == "a cake on a table. make the cake pink")
        #expect(sub1.image.width == 1280 && sub1.image.height == 832, "the source's 3:2 aspect at S4's 1024² pixel count")
        #expect(Self.id(e1) == artifact, "an edit is a version of the same picture")
        var all = try f.versions(artifact)
        #expect(all.count == 2 && all[1].n == 2 && all[1].parentVersionID == v1.id && all[1].operation == "edit")

        // v1 → a second edit (named by v1's version id) → v3, a sibling of v2.
        let (e2, sub2) = try await f.call("edit_image", #"{"prompt":"add candles","source_image_id":"\#(v1.id)"}"#)
        #expect(sub2.image.initImagePath == (try f.path(v1)))
        #expect(Self.id(e2) == artifact)
        all = try f.versions(artifact)
        #expect(all.map(\.n) == [1, 2, 3])
        #expect(all[2].parentVersionID == v1.id && all[2].operation == "edit", "v3's parent is v1, not v2")
        // Nothing deleted: every version keeps its row and its file.
        for v in all { #expect(FileManager.default.fileExists(atPath: try f.path(v))) }
        #expect(Set(all.map(\.blobID)).count == 3)
        // An edit of an edit still carries the generated scene (found up the parent chain), not the earlier instruction.
        let (_, sub3) = try await f.call("edit_image", #"{"prompt":"add a plate","source_image_id":"\#(all[1].id)"}"#)
        #expect(sub3.image.prompt == "a cake on a table. add a plate")
        all = try f.versions(artifact)

        // The stored PNG's provenance matches the row (M4.T09 metadata).
        let info = try #require(MediaProvenanceWriter.info(fromPNG: try Data(contentsOf: URL(fileURLWithPath: try f.path(all[2])))))
        #expect(info.parent == v1.id && info.operation == .edit)
    }

    @Test func uploadedSourceStartsItsOwnArtifact() async throws {
        let f = try Fixture()
        let file = f.dir.appendingPathComponent("upload.png")
        try Self.png(64, 96, gray: 0.5).write(to: file)
        let blob = FileBlobRecord(sha256: String(repeating: "b", count: 64), size: 1, path: file.path, origin: .upload)
        let msg = MessageRecord(chatID: f.chat.id, parentID: nil, role: .user)
        let att = AttachmentRecord(messageID: msg.id, blobID: blob.id, displayName: "upload.png", uti: "public.png")
        try f.db.write { db in try msg.insert(db); try blob.insert(db); try att.insert(db) }

        let (out, sub) = try await f.call("edit_image", #"{"prompt":"make the sky purple","source_image_id":"\#(att.id)"}"#)
        #expect(sub.image.prompt == "make the sky purple", "an upload has no known scene: the instruction alone")
        #expect(sub.image.initImagePath == file.path, "the uploaded file goes in as is (never checked, D-005)")
        let artifact = Self.id(out)
        let vs = try f.versions(artifact)
        #expect(vs.count == 1 && vs[0].parentVersionID == nil && vs[0].operation == "edit")
        #expect(FileManager.default.fileExists(atPath: file.path), "the upload stays")
    }

    /// M4 review: a draft's attachment (no message) or another chat's is never a source.
    @Test func draftOrForeignAttachmentIsNotASource() async throws {
        let f = try Fixture()
        let file = f.dir.appendingPathComponent("draft.png")
        try Self.png(8, 8, gray: 0.5).write(to: file)
        let blob = FileBlobRecord(sha256: String(repeating: "e", count: 64), size: 1, path: file.path, origin: .upload)
        let draft = AttachmentRecord(messageID: nil, blobID: blob.id, displayName: "draft.png", uti: "public.png")
        let other = ChatRecord(mode: .normal)
        let msg = MessageRecord(chatID: other.id, parentID: nil, role: .user)
        let foreign = AttachmentRecord(messageID: msg.id, blobID: blob.id, displayName: "x.png", uti: "public.png")
        try f.db.write { db in try other.insert(db); try msg.insert(db); try blob.insert(db); try draft.insert(db); try foreign.insert(db) }
        for id in [draft.id, foreign.id] {
            #expect(ImageEditFlow.resolve(id, database: f.db, chatID: f.chat.id) == nil)
            #expect(try f.db.read { db in try ImageEditFlow.activeImage(chatID: f.chat.id, userMessageID: nil, explicit: id, db: db) } == nil)
        }
    }

    @Test func inpaintSendsInitAndMaskAndUnknownSourceFails() async throws {
        let f = try Fixture()
        let (created, _) = try await f.call("create_image", #"{"prompt":"a vase"}"#)
        let artifact = Self.id(created)
        let mask = f.dir.appendingPathComponent("mask.png")
        try Self.png(96, 64, gray: 1).write(to: mask)
        let blob = FileBlobRecord(sha256: String(repeating: "c", count: 64), size: 1, path: mask.path, origin: .upload)
        let msg = MessageRecord(chatID: f.chat.id, parentID: nil, role: .user)
        let att = AttachmentRecord(messageID: msg.id, blobID: blob.id, displayName: "mask.png", uti: "public.png")
        try f.db.write { db in try msg.insert(db); try blob.insert(db); try att.insert(db) }
        let (_, sub) = try await f.call("edit_image",
                                        #"{"prompt":"a red tulip","source_image_id":"\#(artifact)","mask_id":"\#(att.id)","mode":"inpaint"}"#)
        #expect(sub.image.initImagePath != nil && sub.image.maskImagePath == mask.path && sub.image.refImagePaths == nil)
        #expect(try f.versions(artifact).last?.operation == "inpaint")

        let (bad, _) = try await f.call("edit_image", #"{"prompt":"x","source_image_id":"no-such-id"}"#)
        #expect(bad == .failed(code: "unknownSourceImage"))
    }

    @Test func pictureInFocusAndContextLine() async throws {
        let f = try Fixture()
        #expect(try f.db.read { db in try ImageEditFlow.activeImage(chatID: f.chat.id, userMessageID: nil, explicit: nil, db: db) } == nil)
        let (created, _) = try await f.call("create_image", #"{"prompt":"a cake"}"#)
        let artifact = Self.id(created)
        _ = try await f.call("edit_image", #"{"prompt":"pink","source_image_id":"\#(artifact)"}"#)
        let v1 = try f.versions(artifact)[0]
        // Default: the chat's newest picture, named by its artifact id.
        let newest = try f.db.read { db in try ImageEditFlow.activeImage(chatID: f.chat.id, userMessageID: nil, explicit: nil, db: db) }
        #expect(newest == .init(id: artifact, origin: .generated, version: 2, versions: 2))
        // The UI named v1 (viewer on an older version): its version id.
        let older = try #require(try f.db.read { db in
            try ImageEditFlow.activeImage(chatID: f.chat.id, userMessageID: nil, explicit: v1.id, db: db)
        })
        #expect(older.id == v1.id && older.version == 1)
        let line = ImageEditFlow.contextLine(older)
        #expect(line.contains("image_id \"\(v1.id)\"") && line.contains("edit_image") && line.contains("version 1 of 2"))
        // An artifact of another chat is never resolved.
        #expect(ImageEditFlow.resolve(artifact, database: f.db, chatID: "other-chat") == nil)
        #expect(ImageEditFlow.resolve(artifact, database: f.db, chatID: f.chat.id) != nil)
    }

    /// The turn names the picture in focus (context line) only when `edit_image` is offered; the UI's pick wins.
    @Test func turnCarriesThePictureInFocus() async throws {
        let edit = RegisteredTool(name: EditImageTool.name, description: EditImageTool.description,
                                  parametersJSON: EditImageTool.parametersJSON, outputIsUntrusted: false) { _ in "{}" }
        let script = #"{"t":"textDelta","v":"ok","delayMs":1}"#
        let h = try ToolLoopHarness(script: script, tier: .t3, tools: [edit, ScriptedTools.getTime()])
        let art = ArtifactRecord(chatID: h.chatID, kind: "image", title: "image.png")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("focus-\(UUID().uuidString).png")
        try Self.png(8, 8, gray: 0.3).write(to: file)
        let blob = FileBlobRecord(sha256: String(repeating: "d", count: 64), size: 1, path: file.path, origin: .generated)
        let v1 = ArtifactVersionRecord(artifactID: art.id, n: 1, blobID: blob.id, operation: .generate)
        try h.database.write { db in
            try ChatRecord(id: h.chatID).insert(db)
            try art.insert(db); try blob.insert(db); try v1.insert(db)
        }
        let (_, a) = await h.send("make it pink")
        _ = try await h.log.waitFinished(a)
        let line = try #require(await h.controller.lastImageContextLine)
        #expect(line.contains("image_id \"\(art.id)\""))

        await h.controller.setActiveImageNextTurn(v1.id)
        let (_, b) = await h.send("add candles")
        _ = try await h.log.waitFinished(b)
        #expect(await h.controller.lastImageContextLine?.contains(art.id) == true, "v1 is the newest: named by its artifact id")

        let plain = try ToolLoopHarness(script: script, tier: .t3, tools: [ScriptedTools.getTime()])
        let (_, c) = await plain.send("hello")
        _ = try await plain.log.waitFinished(c)
        #expect(await plain.controller.lastImageContextLine == nil, "no edit tool offered → no line")
    }

    /// Quick (default) = the create model; the user's Best quality (TurnContext.imageEditBest) = img-edit where installed, else quick.
    @Test func bestQualityPicksTheEditModel() async throws {
        let f = try Fixture()
        let (created, _) = try await f.call("create_image", #"{"prompt":"a cake"}"#)
        let art = Self.id(created)
        let db = f.db, q = f.queue, chat = f.chat.id
        func run(_ best: Bool, _ photo: BestPhoto) async throws -> MediaJobSubmit {
            let before = f.transport.submittedJobs.count
            let args = #"{"prompt":"pink","source_image_id":"\#(art)"}"#
            let t = Task {
                try await TurnContext.$imageEditBest.withValue(best) {
                    try await ToolCallStore.$database.withValue(db) { try await ImageTools.run("edit_image", args, queue: q, photo: photo, chatID: chat) }
                }
            }
            for _ in 0..<500 where f.transport.submittedJobs.count == before { try await Task.sleep(for: .milliseconds(5)) }
            let sub = f.transport.submitted[before]
            f.transport.end(sub.job, .jobCancelled(job: sub.job))
            _ = try await t.value
            return sub
        }
        #expect(try await run(false, BestPhoto(hasBest: true)).image.model.key == "img-klein-q8", "quick is the default")
        let best = try await run(true, BestPhoto(hasBest: true))
        #expect(best.image.model.key == "img-edit-q4" && best.image.refImagePaths != nil)
        #expect(try await run(true, BestPhoto(hasBest: false)).image.model.key == "img-klein-q8", "best falls back to quick")
    }

    @Test func editResolutionKeepsTheSourceAspect() {
        #expect(ImageEditFlow.resolution(source: (1024, 1024), speed: .s1, stepDown: false) == (768, 768))
        #expect(ImageEditFlow.resolution(source: (1500, 1000), speed: .s4, stepDown: false) == (1280, 832))
        #expect(ImageEditFlow.resolution(source: (1000, 1500), speed: .s3, stepDown: true) == (640, 960))
        var r = ImageRequest(model: FakePhoto.set, prompt: "p", width: 64, height: 64, seed: 1, outputPath: "")
        ImageEditFlow.apply(mode: "edit", source: "/s.png", mask: nil, to: &r)
        #expect(r.initImagePath == "/s.png" && r.strength == 0.6 && r.refImagePaths == nil, "klein: img2img")
        var q = ImageRequest(model: BestPhoto.qwen, prompt: "p", width: 64, height: 64, seed: 1, outputPath: "")
        ImageEditFlow.apply(mode: "edit", source: "/s.png", mask: nil, to: &q)
        #expect(q.refImagePaths == ["/s.png"] && q.initImagePath == nil && q.strength == nil, "img-edit: reference picture")
        // Masked instruction edits keep the mask (the helper composites the result back onto the source).
        var km = ImageRequest(model: FakePhoto.set, prompt: "p", width: 64, height: 64, seed: 1, outputPath: "")
        ImageEditFlow.apply(mode: "edit", source: "/s.png", mask: "/m.png", to: &km)
        #expect(km.initImagePath == "/s.png" && km.maskImagePath == "/m.png" && km.strength == 0.6)
        var qm = ImageRequest(model: BestPhoto.qwen, prompt: "p", width: 64, height: 64, seed: 1, outputPath: "")
        ImageEditFlow.apply(mode: "edit", source: "/s.png", mask: "/m.png", to: &qm)
        #expect(qm.refImagePaths == ["/s.png"] && qm.maskImagePath == "/m.png" && qm.initImagePath == nil)
        ImageEditFlow.apply(mode: "inpaint", source: "/s.png", mask: "/m.png", to: &r)
        #expect(r.refImagePaths == nil && r.initImagePath == "/s.png" && r.maskImagePath == "/m.png")
    }
}

extension FakePhoto {
    static let set = ImageModelSet(key: "img-klein-q8", diffusionModel: "/m/d.gguf", llm: "/m/te.gguf", vae: "/m/vae.safetensors",
                                   footprintBytes: 6_000_000_000)
}

struct BestPhoto: PhotoModelProviding {
    static let qwen = ImageModelSet(key: "img-edit-q4", diffusionModel: "/m/q.gguf", llm: "/m/vl.gguf", vae: "/m/qv.safetensors",
                                    footprintBytes: 24_000_000_000)
    var hasBest: Bool
    func modelSet(for tool: String) async -> ImageModelSet? { tool == EditImageTool.bestModelKey ? (hasBest ? Self.qwen : nil) : FakePhoto.set }
    func speedClass() async -> ImageSpeedClass { .s4 }
    func safetyManifest() async -> SafetyManifest? { FakeSafety.installed }
    func imagePath(_ id: String) async -> String? { nil }
}
