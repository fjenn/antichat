// AT-021 check 1 (R-021 AC1; M6.T05 steps 1–3): images are prepared for the vision model (long side ≤ 1024, never
// upscaled, EXIF orientation applied, PNG in the transfer dir / incognito temp dir) and only their paths cross XPC
// (the encoded request stays < 64 KB); a turn with an image goes to the model's vision slot with the prepared path
// (`vision: model`), a text-only model gets no image and the reply records `vision: unavailable` (the
// img.needsLargerModel card) — the OCR text is in the prompt either way.
//   make test-unit FILTER=VisionInputTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import AntiChatHarness

private final class ImageEngine: EngineService {
    let inner: InProcessScriptedEngine
    let requests = Mutex<[ChatRequest]>([])
    init() throws { inner = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok","delayMs":1}"#)) }
    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        return inner.chat(request, onLifecycle: onLifecycle)
    }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    var lastUser: ChatMessage? {
        requests.withLock { $0.last }?.flattenedMessages.last { $0.role == .user }
    }
}

@Suite struct VisionInputTests {
    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    static func size(_ url: URL) -> (Int, Int) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
    }

    /// A media root for test intakes. Not `AttachmentIntake.incognitoRoot()`: that names `$TMPDIR/AntiChat-incognito-*`,
    /// which any AntiChat.app launching on this Mac sweeps (`IncognitoSession.sweepStaleTempDirectories`, the app is not
    /// sandboxed, so it shares `swift test`'s temp dir). Under a busy Mac a launch deleted the image mid-turn.
    static func mediaRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("test-media-\(UUID().uuidString)", isDirectory: true)
    }

    static func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func downscalesToTheMaxSideAndNeverUpscales() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prep = ImageInputPreparer(directory: dir.appendingPathComponent("xfer"))
        let big = dir.appendingPathComponent("big.png")
        let ctx = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        let d = CGImageDestinationCreateWithURL(big as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(d))
        let (w0, h0) = Self.size(big)
        let out = try prep.prepare(big)
        let (w, h) = Self.size(out)
        #expect(max(w0, h0) > 1024 && max(w, h) == 1024 && out.pathExtension == "png")
        #expect(abs(Double(w) / Double(h) - Double(w0) / Double(h0)) < 0.01)
        #expect(out.deletingLastPathComponent().standardizedFileURL == dir.appendingPathComponent("xfer").standardizedFileURL)
        #expect(try prep.prepare(big) == out, "same image, same file")
        let small = Self.fixtures.appendingPathComponent("images/photos-cc0/001.jpg")  // 1024 px: kept, not upscaled
        let (sw, sh) = Self.size(small)
        #expect(Self.size(try ImageInputPreparer(directory: dir.appendingPathComponent("x2"), maxSide: 2048).prepare(small)) == (sw, sh))
    }

    @Test func exifOrientationIsApplied() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 200×100 pixels tagged orientation 6 (rotate 90° CW to display) → shown 100×200.
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let jpg = dir.appendingPathComponent("rot.jpg")
        let dst = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dst))
        let out = try ImageInputPreparer(directory: dir.appendingPathComponent("x")).prepare(jpg)
        #expect(Self.size(out) == (100, 200))
    }

    @Test func onlyPathsCrossXPC() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try ImageInputPreparer(directory: dir).prepare(Self.fixtures.appendingPathComponent("images/photos-cc0/002.jpg"))
        let fileBytes = try Data(contentsOf: png).count
        let req = ChatRequest(sessionID: UUID(), modelSlot: ModelSlot(engine: .mlx, key: "chat-9b-q4+vision", path: "/m", vision: true),
                              messages: [.message(ChatMessage(role: .user, content: "What is this?", imagePaths: [png.path]))])
        let wire = try JSONEncoder().encode(ClientMessage.chat(req))
        #expect(fileBytes > 64 * 1024 && wire.count < 64 * 1024, "image \(fileBytes) B, wire \(wire.count) B")
    }

    @Test func visionSlotFollowsTheModel() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"qwen3_5","vision_config":{}}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        let vlm = VisionRouting.defaultVisionSlot(ModelSlot(engine: .mlx, key: "chat-9b-q4", path: dir.path))
        #expect(vlm?.key == "chat-9b-q4+vision" && vlm?.vision == true)
        try Data(#"{"model_type":"lfm2"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(VisionRouting.defaultVisionSlot(ModelSlot(engine: .mlx, key: "chat-lfm3", path: dir.path)) == nil)
        let gguf = ModelSlot(engine: .llama, key: "evil-9b", path: "/x", vision: true)
        #expect(VisionRouting.defaultVisionSlot(gguf) == gguf)
        #expect(VisionRouting.defaultVisionSlot(ModelSlot(engine: .llama, key: "g", path: "/x")) == nil)
        #expect(ModelToolCapability.supportsTools(modelKey: "chat-9b-q4+vision"))
        #expect(!ModelToolCapability.supportsTools(modelKey: "chat-0.8b+vision"))
    }

    private func turn(vision: Bool) async throws -> (ImageEngine, MessageProvenance.FileUse?, AppDatabase, URL) {
        let db = try AppDatabase.inMemory()
        let engine = try ImageEngine()
        let xfer = try Self.scratch()
        let slot = ModelSlot(engine: .scripted, key: "scripted", path: "", vision: vision)
        let env = ChatEnvironment(database: db, engine: engine, contextPolicy: ContextPolicy(windowOverride: 32_768),
                                  vision: VisionRouting(preparer: { _ in ImageInputPreparer(directory: xfer) }),
                                  slot: { slot })
        let intake = AttachmentIntake(database: db, mediaRoot: Self.mediaRoot(), incognito: true)
        let item = await intake.ingest(AttachmentIntake.admit([Self.fixtures.appendingPathComponent("images/ocr/doc-00.png")]).items[0])
        let att = try #require(item.attachmentID)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "What is the reference code?", parentID: nil, attachmentIDs: [att]),
                      assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        let use = try MessageRepository(db).message(a)?.provenance?.files?.first { $0.attachmentID == att }
        return (engine, use, db, xfer)
    }

    @Test func aVisionModelGetsThePreparedImage() async throws {
        let (engine, use, _, xfer) = try await turn(vision: true)
        defer { try? FileManager.default.removeItem(at: xfer) }
        let user = try #require(engine.lastUser)
        #expect(user.imagePaths.count == 1)
        #expect(user.imagePaths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL } == xfer.standardizedFileURL)
        #expect(use?.vision == "model")
        #expect(user.content.contains("Text found in image:") && user.content.contains("untrusted=\"true\""))
    }

    @Test func aTextOnlyModelGetsNoImageAndTheCardSaysSo() async throws {
        let (engine, use, _, xfer) = try await turn(vision: false)
        defer { try? FileManager.default.removeItem(at: xfer) }
        let user = try #require(engine.lastUser)
        #expect(user.imagePaths.isEmpty)
        #expect(use?.vision == "unavailable")
        #expect(user.content.contains("Text found in image:"), "OCR text is attached either way")
    }
}
