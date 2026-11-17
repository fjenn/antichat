// M9.T05 (AT-236 AC3, `make perf METRIC=IMAGE_TURN_OVERHEAD TIER=T1`): an image turn through the app's real path —
// TurnController with the media tools installed (ToolRuntime.installMedia: the app's MediaJobQueue + ImageTools over
// XPC), the composer's Image chip forcing `create_image`, the helper's chat → diffusion step-aside, sd-server, the
// ChildSafetyCheck gate on the final image, the artifact save and the templated caption (T0–T2, R-236).
//   AntiChat -Bench image-turn --tier-cap T1 [--model chat-9b-q4] [--quant q4] [--runs 10] [--raw out.jsonl]
// Timing comes from the perf log (`ANTICHAT_PERF_LOG`, set by tools/perf/run.py): per turn one `imageTurn` interval
// (TurnController: send → the turn's reply written) and one `imageGen` interval (MediaJobQueue: the helper's
// image.loadStart → image.final for the job). IMAGE_TURN_OVERHEAD = imageTurn − imageGen (bar p50 ≤ 2 s). Run 0 is
// discarded (Metal pipeline cache, first sd-server start). The chat model is resident before each send (a
// conversation before "draw …"); every run uses a fresh chat. Debug build (dev models, dev detector files).
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Foundation

extension BenchMode {
    /// The installed photo models of the bench: the dev klein set at `quant`, the speed class's base resolution.
    struct BenchPhotoModels: PhotoModelProviding {
        let quant: String
        let speed: ImageSpeedClass
        func modelSet(for tool: String) async -> ImageModelSet? {
            tool == "create_image" ? DevModels.imageSet(quant, res: speed.baseSide) : nil
        }
        func speedClass() async -> ImageSpeedClass { speed }
        func safetyManifest() async -> SafetyManifest? { BenchMode.benchSafety }
        func imagePath(_ id: String) async -> String? { nil }
    }

    static func imageTurn(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let cap = a.opts["tier-cap"] ?? "T1"
        let family = String(cap.prefix(2))
        let tier = DeviceTier(rawValue: family) ?? .t1
        let low = tier == .t0 || tier == .t1 || tier == .t2
        let chatKey = a.opts["model"] ?? ["T0": "chat-2b", "T3": "chat-35b-q4", "T4": "chat-35b-q4"][family] ?? "chat-9b-q4"
        let slot = DevModels.slot(chatKey)
        let budget = UInt64((DevModels.tierB[cap] ?? 0) * 1e9)
        try await client.setPolicy(SetPolicy(budgetB: budget, lowTier: low))
        // S1/S2 → 768², S3/S4 → 1024² (ImageRequestBuilder); the T1 bar is judged at 768² (`--res 1024` for S3+).
        let speed: ImageSpeedClass = a.int("res", 768) >= 1024 ? .s3 : .s2
        let photo = BenchPhotoModels(quant: a.opts["quant"] ?? "q4", speed: speed)
        guard await photo.safetyManifest() != nil else {
            throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "no ChildSafetyCheck detector files (dev models)"])
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-image-turn-\(getpid())")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: work.appendingPathComponent("antichat.sqlite"))
        var tools = ToolRuntime(registry: ToolRegistry(), policy: .forTier(tier), tier: { tier })
        tools.installMedia(database: db, transport: client, xferRoot: work.appendingPathComponent("xfer"), photo: photo, video: nil)
        let prompts = (try? prompts(a)) ?? []
        let runs = a.int("runs", 10)
        var b = base
        b["perf_log"] = PerfRecorder.isEnabled
        b["chat"] = slot.key
        b["speed"] = speed.rawValue
        say("image-turn: cap \(cap) (\(tier.rawValue), lowTier \(low)) chat \(slot.key) image \(photo.quant)@\(speed.baseSide) runs \(runs)+1 perf log \(PerfRecorder.isEnabled)")
        for i in 0...runs {
            for await _ in client.warmupBatches(slot) {}  // the chat model is resident when the user asks for a picture
            let chat = ChatRecord(mode: .normal)
            try db.write { try chat.insert($0) }
            let c = TurnController(chatID: chat.id, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: 256, seed: 7), tools: tools) { slot }
            await c.setChips(["image"])  // the composer's Image chip: the first step must call create_image (R-235 AC1)
            let subject = prompts.isEmpty ? "a red cube on a wooden table, studio light" : prompts[i % prompts.count].0
            let aid = StorageID.make()
            let t0 = ContinuousClock.now
            let watch = Task { () -> (Double, String, String) in
                var text = ""
                for await u in c.updates where u.assistantID == aid {
                    switch u.kind {
                    case .textDelta(let d): text += d
                    case .finished(let r): return (secs(ContinuousClock.now - t0), "\(r.status)", text)
                    default: break
                    }
                }
                return (secs(ContinuousClock.now - t0), "ended", text)
            }
            await c.start(.send(userID: StorageID.make(), text: "Draw \(subject).", parentID: nil, attachmentIDs: []), assistantID: aid)
            let (turn, status, text) = await watch.value
            let images = (try? db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_job WHERE chat_id = ? AND state = 'done'",
                                                           arguments: [chat.id]) }) ?? 0
            var o = b
            o["kind"] = i == 0 ? "warm" : "run"
            o["run"] = i
            o["turn_s"] = turn
            o["status"] = status
            o["caption"] = text
            o["images_done"] = images
            raw.write(o)
            say(String(format: "%@: send → reply %.2f s, %@, images done %d, caption \"%@\"", i == 0 ? "warm" : "run \(i)", turn, status,
                       images, text))
        }
        for await _ in client.evict() {}
    }
}
#endif
