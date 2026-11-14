// `antichat-bench router` (M2.T22/T23; R-235 AC2/AC4). The pre-router over the real helper: the `embed` model through
// XPC (HelperEmbedder) and the bundled prototypes.
//   --runs N                  latency: N sends (router-300 texts in turn), p50/p95 of RouteScorer.score (XPC embed +
//                             CPU), and of the two parts alone (embed request; CPU scoring of the returned vector)
//   --dump --set calib|test|all   one row per prompt {id, lang, label, attachment, scores} (tools/router/fit.py input)
//   --stack --model <key> --set test   M2.T23 full stack (pre-router + chat model + fallback re-ask) per prompt through a
//                             TurnController on the real chat model with stub media/web/file/memory tools; one row per
//                             prompt {id, label, top, confident, called[], reasks, offer} (tools/router/accuracy.py)
//   --cards --model <key>     M2.T24 AT-238: fixtures/prompts/media-100.jsonl through the full stack with Photo and Video
//                             NOT installed (a fixed PackInstalling); one row per request {id, label, card, card_state,
//                             text, called[], requests} → --turns <jsonl> (tools/eval/judge-media-claims.py). A row
//                             with `attachment: image` sends a real photo (`--image`, default the CC0 landscape
//                             fixtures/images/photos-cc0/019.jpg, no people): an attachment row on the user message, and
//                             the picture in the request's last user message, as image attachments reach the model
//                             from M4 on (until then TurnController takes the attachment as the router hint only).
//                             Also reports `pack_match` (card pack == labelled medium; bar ≥ 98/100).
//   --real-image-tool          (with --stack) M4.T07 AT-030 AC1: `create_image` offered with its real contract
//                             (CreateImageTool name/description/schema; the call returns a done outcome, no job)
//   --json <out>              result file;  --fixtures <dir> (default $ANTICHAT_FIXTURES or ./fixtures);  --cap <tier>
// The prototype cache goes to a temp dir unless --cache <dir>.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AntiChatFoundation
import AntiChatTools
import CryptoKit
import Foundation
import Synchronization

enum RouterBench {
    struct Row: Decodable { var id: String; var lang: String; var text: String; var label: String; var attachment: String? }

    static func rows(_ a: BenchArgs) throws -> [Row] {
        let fx = a["fixtures"] ?? ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] ?? "fixtures"
        let file = a["cards"] != nil ? "media-100" : "router-300"
        let all = try String(contentsOfFile: "\(fx)/prompts/\(file).jsonl", encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let set = a["set"] ?? "all"
        guard set != "all" else { return all }
        let split = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(fx)/prompts/router-300.split.json")))
        guard let ids = (split as? [String: Any])?[set] as? [String] else { throw BenchError("--set \(set): not in the split") }
        let keep = Set(ids)
        return all.filter { keep.contains($0.id) }
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// The stub tools of the full-stack run (read-only, so no ApprovalCard; a scripted result like ScriptedImageEngine's).
    /// M4.T07: the real `create_image` contract instead of the stub (AT-030 AC1 "with the real create_image tool").
    nonisolated(unsafe) static var realImageTool = false

    static func stubTools() -> [RegisteredTool] {
        let tools = stubToolsM2()
        guard realImageTool else { return tools }
        let done = ImageTurnPolicy.Outcome.done(imageID: "bench", width: 1024, height: 1024).resultJSON
        return tools.map { t in
            t.name != CreateImageTool.name ? t
                : RegisteredTool(name: CreateImageTool.name, description: CreateImageTool.description,
                                 parametersJSON: CreateImageTool.parametersJSON, outputIsUntrusted: false) { _ in done }
        }
    }

    static func stubToolsM2() -> [RegisteredTool] {
        let schema = #"{"type":"object","properties":{"prompt":{"type":"string","description":"What to make, search or store"}},"required":["prompt"]}"#
        let defs: [(String, String)] = [
            ("create_image", "Create a picture from a text description."), ("create_video", "Create a short video clip from a text description."),
            ("web_search", "Search the web for current information."), ("create_file", "Create a downloadable file (PDF, document, spreadsheet, …)."),
            ("memory_write", "Remember a fact about the user for future chats."),
        ]
        return defs.map { n, d in
            RegisteredTool(name: n, description: d, parametersJSON: schema, outputIsUntrusted: false) { _ in #"{"status":"done"}"# }
        } + [ScriptedTools.getTime()]
    }

    static func stack(_ a: BenchArgs, rows: [Row], client: EngineClient, scorer: RouteScorer, cap: String) async throws -> [[String: Any]] {
        let slot = DevSlots.slot(a["model"] ?? "chat-9b-q4")
        let tier: DeviceTier = cap.hasPrefix("T2") ? .t2 : cap.hasPrefix("T3") ? .t3 : cap.hasPrefix("T0") ? .t0 : .t1
        let router = PreRouter(scorer: scorer, enabled: { true })
        var turns: [[String: Any]] = []
        for (i, r) in rows.enumerated() {
            let db = try AppDatabase.inMemory()
            let reg = ToolRegistry(stubTools())
            let rt = ToolRuntime(registry: reg, permissions: ToolPermissionStore(db), policy: .forTier(tier), selection: .standard,
                                 router: router, tier: { tier })
            let c = TurnController(chatID: StorageID.make(), database: db, engine: client,
                                   sampling: Sampling(maxTokens: a.int("max-tokens", 200), seed: 7), tools: rt) { slot }
            await c.setImageAttached(r.attachment != nil)
            // M2.T23b: the composer embeds the draft while the user types (RoutePrefetch); the send finds it cached.
            // Accuracy run: wait for the vector however long the embed takes on a loaded host (up to 60 s). A 2 s cap
            // sent 4/200 turns unscored under load 60 (AT-030 run 2026-11-08: skipped = timedOut, top chat) — the send
            // budget is R-235 AC2's latency bar (RouterBench --runs), not part of the routing accuracy measured here.
            await scorer.prefetch(r.text)
            for _ in 0..<12_000 where !(await scorer.isPrefetched(r.text)) { try? await Task.sleep(for: .milliseconds(5)) }
            let prefetched = await scorer.isPrefetched(r.text)
            let aid = StorageID.make()
            let t = ContinuousClock.now
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: r.text, parentID: nil), assistantID: aid)
            let res = await done.value
            let d = await c.lastRouteDecision
            let called = stubTools().map(\.name).filter { reg.invocations(of: $0) > 0 }
            var row: [String: Any] = [
                "id": r.id, "lang": r.lang, "label": r.label, "top": d?.top?.rawValue ?? "chat", "confident": d?.confident ?? false,
                "exposed": d?.toolsToExpose.map(\.name) ?? [], "called": called, "reasks": await c.lastFallbackReasks,
                "offer": (await c.lastMediaOffer)?.kind.rawValue ?? "", "status": res.map { "\($0.status)" } ?? "none",
                "secs": ms(ContinuousClock.now - t) / 1000, "skipped": d?.skipped?.rawValue ?? "", "prefetched": prefetched,
                "scores": Dictionary(uniqueKeysWithValues: (d?.scores ?? [:]).map { ($0.key.rawValue, Double($0.value)) }),
                "text": String((res?.text ?? "").prefix(160)),
            ]
            if let err = res?.errorCode { row["error"] = err }
            turns.append(row)
            say("\(i + 1)/\(rows.count) \(r.id) \(r.label) → called \(called) top \(row["top"]!) reask \(row["reasks"]!)")
        }
        return turns
    }

    /// Photo and Video not installed (sizes of the T1 selection's order of magnitude; the card only shows them).
    struct NotInstalled: PackInstalling {
        func availability(_ pack: MediaPack) async -> PackAvailability {
            pack == .photo ? .installable(bytes: 6_400_000_000, minutes: 17) : .installable(bytes: 18_000_000_000, minutes: 48)
        }
        func install(_ pack: MediaPack) async -> PackInstallStart { .failed }
    }

    static func cards(_ a: BenchArgs, rows: [Row], client: EngineClient, scorer: RouteScorer, cap: String) async throws -> [[String: Any]] {
        let slot = DevSlots.slot(a["model"] ?? "chat-9b-q4")
        let tier: DeviceTier = cap.hasPrefix("T2") ? .t2 : cap.hasPrefix("T3") ? .t3 : cap.hasPrefix("T0") ? .t0 : .t1
        let router = PreRouter(scorer: scorer, enabled: { true })
        let fx = a["fixtures"] ?? ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] ?? "fixtures"
        let photoPath = URL(fileURLWithPath: a["image"] ?? "\(fx)/images/photos-cc0/019.jpg").standardizedFileURL.path
        let bytes = try Data(contentsOf: URL(fileURLWithPath: photoPath))
        let photo = (path: photoPath, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        say("attachment rows send \(photoPath) (sha256 \(photo.sha256.prefix(12))…)")
        var turns: [[String: Any]] = []
        for (i, r) in rows.enumerated() {
            let db = try AppDatabase.inMemory()
            let reg = ToolRegistry(stubTools())
            let rt = ToolRuntime(registry: reg, permissions: ToolPermissionStore(db), policy: .forTier(tier), selection: .standard,
                                 router: router, tier: { tier })
            let image = r.attachment == "image" ? photo : nil
            let counter = RequestCounter(client, image: image?.path)
            var attachmentIDs: [String] = []
            if let image {
                let att = try AttachmentRepository(db).insert(sha256: image.sha256, size: image.size, path: image.path,
                                                              origin: .upload, messageID: nil,
                                                              displayName: URL(fileURLWithPath: image.path).lastPathComponent,
                                                              uti: "public.jpeg")
                attachmentIDs = [att.id]
            }
            let c = TurnController(chatID: StorageID.make(), database: db, engine: counter,
                                   sampling: Sampling(maxTokens: a.int("max-tokens", 200), seed: 7), tools: rt,
                                   packs: NotInstalled()) { slot }
            await c.setImageAttached(r.attachment != nil)
            await scorer.prefetch(r.text)  // as in the app: typed before the send (RoutePrefetch)
            for _ in 0..<400 where !(await scorer.isPrefetched(r.text)) { try? await Task.sleep(for: .milliseconds(5)) }
            let prefetched = await scorer.isPrefetched(r.text)
            let aid = StorageID.make()
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: r.text, parentID: nil, attachmentIDs: attachmentIDs), assistantID: aid)
            let res = await done.value
            let card = await c.lastInstallCard
            let called = stubTools().map(\.name).filter { reg.invocations(of: $0) > 0 }
            let decision = await c.lastRouteDecision
            let row: [String: Any] = [
                "skipped": decision?.skipped?.rawValue ?? "", "prefetched": prefetched,
                "id": r.id, "lang": r.lang, "label": r.label, "card": card != nil, "card_pack": card?.pack.rawValue ?? "",
                "card_state": card.map { "\($0.state)" } ?? "", "text": res?.text ?? "", "called": called,
                "requests": counter.count.withLock { $0 }, "top": decision?.top?.rawValue ?? "chat",
                "status": res.map { "\($0.status)" } ?? "none", "image": image.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "",
            ]
            turns.append(row)
            say("\(i + 1)/\(rows.count) \(r.id) \(r.label) → card \(card?.pack.rawValue ?? "-") top \(row["top"]!) skipped \(row["skipped"]!) requests \(row["requests"]!) text \((res?.text ?? "").prefix(60))")
        }
        return turns
    }

    static func run(_ a: BenchArgs) async throws {
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9)))
        let embedSlot = DevSlots.slot("embed")
        let embedder = HelperEmbedder(engine: client, embedSlot: { embedSlot })
        guard let protos = RoutePrototypes.bundled else { throw BenchError("route-prototypes.json missing") }
        let cache = a["cache"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "antichat-router-\(UUID().uuidString)")
        let scorer = RouteScorer(prototypes: protos, embedding: embedder, cacheDirectory: cache)
        let t0 = ContinuousClock.now
        guard await scorer.prepare() else {
            do { _ = try await embedder.embed(["probe"]) } catch { throw BenchError("prototype embedding failed: \(error)") }
            throw BenchError("prototype embedding failed (is `embed` installed? make models-dev)")
        }
        say("prototypes \(protos.rows.count) ready in \(Int(ms(ContinuousClock.now - t0))) ms")
        var rows = try rows(a)
        if let n = a["limit"].flatMap(Int.init) { rows = Array(rows.prefix(n)) }
        var out: [String: Any] = ["cap": cap, "prototypes": protos.rows.count, "prototypes_sha256": protos.sha256]
        if a["dump"] != nil {
            var dump: [[String: Any]] = []
            for r in rows {
                guard let s = await scorer.score(r.text, hasImage: r.attachment != nil) else { throw BenchError("score failed: \(r.id)") }
                var row: [String: Any] = ["id": r.id, "lang": r.lang, "label": r.label,
                                          "scores": Dictionary(uniqueKeysWithValues: s.map { ($0.key.rawValue, Double($0.value)) })]
                if let att = r.attachment { row["attachment"] = att }
                dump.append(row)
            }
            out["set"] = a["set"] ?? "all"
            out["rows"] = dump
        }
        if a["cards"] != nil {
            out["model"] = a["model"] ?? "chat-9b-q4"
            let turns = try await cards(a, rows: rows, client: client, scorer: scorer, cap: cap)
            out["turns"] = turns
            // M2.T26 fix: the card names the labelled medium (video_* → video, image_* → photo) on ≥ 98/100.
            let carded = turns.filter { ($0["card"] as? Bool) == true }
            let match = carded.filter { t in
                let label = t["label"] as? String ?? "", pack = t["card_pack"] as? String ?? ""
                return label.hasPrefix("video") ? pack == "video" : label.hasPrefix("image") ? pack == "photo" : false
            }
            out["pack_match"] = match.count
            out["pack_mismatch_ids"] = carded.filter { c in !match.contains { ($0["id"] as? String) == (c["id"] as? String) } }
                .compactMap { $0["id"] as? String }
            say("cards \(carded.count)/\(turns.count); card pack == labelled medium \(match.count)/\(turns.count)")
            if let path = a["turns"] {
                let lines = try turns.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if a["stack"] != nil {
            out["model"] = a["model"] ?? "chat-9b-q4"
            out["set"] = a["set"] ?? "all"
            realImageTool = a["real-image-tool"] != nil
            out["turns"] = try await stack(a, rows: rows, client: client, scorer: scorer, cap: cap)
        }
        let runs = a.int("runs", 0)
        if runs > 0 {
            var total: [Double] = [], embed: [Double] = [], cpu: [Double] = [], send: [Double] = [], cold: [Double] = []
            for i in 0..<(runs + 1) {
                let r = rows[i % rows.count]
                let t = ContinuousClock.now
                _ = await scorer.score(r.text, hasImage: r.attachment != nil)
                let tTotal = ms(ContinuousClock.now - t)
                let e = ContinuousClock.now
                let v = try await embedder.embed([r.text])[0]
                let tEmbed = ms(ContinuousClock.now - e)
                var unit = v
                let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
                if n > 0 { unit = v.map { $0 / n } }
                let c = ContinuousClock.now
                _ = await scorer.scores(for: unit, hasImage: r.attachment != nil)
                let tCPU = ms(ContinuousClock.now - c)
                // M2.T23b: the send-time cost — the draft was prefetched while typing (cached vector, CPU scoring only)
                // — and the cold path (no prefetch: the send waits at most PreRouter.sendBudget).
                let fresh = r.text + " \(i)"
                await scorer.prefetch(fresh)
                for _ in 0..<400 where !(await scorer.isPrefetched(fresh)) { try? await Task.sleep(for: .milliseconds(2)) }
                let s0 = ContinuousClock.now
                _ = await scorer.score(fresh, hasImage: r.attachment != nil, within: PreRouter(scorer: nil).sendBudget)
                let tSend = ms(ContinuousClock.now - s0)
                let c0 = ContinuousClock.now
                _ = await scorer.score(fresh + " cold", hasImage: r.attachment != nil, within: PreRouter(scorer: nil).sendBudget)
                let tCold = ms(ContinuousClock.now - c0)
                if i == 0 { continue }  // warm-up (model load)
                total.append(tTotal); embed.append(tEmbed); cpu.append(tCPU); send.append(tSend); cold.append(tCold)
            }
            func q(_ xs: [Double]) -> [String: Double] { ["p50": Stats.quantile(xs, 0.5), "p95": Stats.quantile(xs, 0.95), "max": xs.max() ?? -1] }
            out["latency_ms"] = ["n": runs, "total": q(total), "embed_xpc": q(embed), "cpu": q(cpu),
                                 "send_prefetched": q(send), "send_cold_capped": q(cold),
                                 "send_budget_ms": PreRouter(scorer: nil).sendBudget.map { ms($0) } ?? -1]
        }
        if let path = a["json"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        if let l = out["latency_ms"] { say("latency \(l)") }
        say("rows \(rows.count)")
    }
}

/// Counts the chat requests that reach the engine (AT-238: a carded turn sends none). `image`: the turn's attached
/// photo, put on the newest user message (`ChatRequest.images`), as M4's photo attachments will deliver it.
final class RequestCounter: EngineService, @unchecked Sendable {
    let inner: any EngineService
    let image: String?
    let count = Mutex(0)
    init(_ inner: any EngineService, image: String? = nil) { self.inner = inner; self.image = image }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await inner.warmup(slot, onLifecycle: onLifecycle)
    }
    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        count.withLock { $0 += 1 }
        guard let image else { return inner.chat(request, onLifecycle: onLifecycle) }
        var r = request
        r.images.append(URL(fileURLWithPath: image))  // flattened onto the newest user message
        return inner.chat(r, onLifecycle: onLifecycle)
    }
}
