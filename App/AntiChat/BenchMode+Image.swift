// M0.T06 bench commands (S-5): `AntiChat -Bench image|handoff|coresident|cancel …`, driven through the real XPC
// path into the helper's EngineRuntime (ModelScheduler job) and its sd-server child. Safety floor (M0.md M0.T06, D-006): images
// and previews are never shown in any UI; the helper writes PNGs to --out-dir and the raw rows carry hashes.
//   image      --quant q4|q8 --res 768|1024 --runs 20 --prompts FILE --out-dir DIR [--tier-cap T]
//              P1 (request → final), the first denoise step (request → first step event, `first_step_s`), previews per
//              job, peak footprint. M9.T05: NFR-P2 is NOT this number any more. Under A-M4-R1/A-M4-R1b a step preview
//              below 512 px (every sd-server `proj` preview here, ~128 px) is withheld and the card shows its progress
//              state instead, so the first visible "preview" is that state — measured on screen by the XCUITest leg
//              ImageFirstVisiblePerfTests (`imageFirstVisible`). The step-1 time stays as a diagnostic (sd-scale
//              `m0.P2step1.*`); `first_preview_s` is kept as its old alias for older readers.
//   handoff    --tier-cap T1 --model chat-9b-q4 --quant q4 --res 768 --runs 20 --prompts FILE --out-dir DIR
//              NFR-M3: evict → image → reload; a chat request sent at the image result is queued and answered.
//   coresident --tier-cap T2-24 --model chat-9b-q4 --quant q8 --res 1024 --runs 10 …   (R-236: no eviction)
//   cancel     --quant q4 --res 1024 --runs 10 --cancel-step 2 …   (M9.T05: cancel → stopped and → memory freed ≤ 2 s)
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Darwin
import Foundation
import os

extension BenchMode {
    struct ImageRun {
        var progress: [ImageProgress] = []
        var firstPreview: Double?
        var final: Double?
        var result: ImageResult?
        var notes: [SchedulerNote] = []
        var error: String?
        var sdPID: Int32 = 0
        var chatAtResult: ChatProbe?
    }

    struct ChatProbe {
        var ttft: Double?
        var tokens = 0
        var loadStates: [String] = []
        var error: String?
        var loadTime: Double?
        var text = ""
    }

    final class PIDSet: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Set<pid_t>())
        func insert(_ p: pid_t) { lock.withLock { _ = $0.insert(p) } }
        var all: [pid_t] { lock.withLock { Array($0) } }
    }

    static func prompts(_ a: Args) throws -> [(String, Int64)] {
        let path = a.opts["prompts"] ?? "fixtures/images/prompts-50.json"
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        let rows = obj?["prompts"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let p = r["prompt"] as? String, let s = (r["seed"] as? NSNumber)?.int64Value else { return nil }
            return (p, s)
        }
    }

    /// Sends one image job; when `chatAfter` is set, a chat request is sent the moment the image result
    /// arrives (it must queue behind the reload, NFR-M3) and its first token is timed from that instant.
    static func runImage(
        _ client: EngineClient, _ req: ImageRequest, cancelAtStep: Int? = nil, chatAfter: ModelSlot? = nil,
        pids: PIDSet
    ) async -> ImageRun {
        var r = ImageRun()
        let sent = ContinuousClock.now
        var chatTask: Task<ChatProbe, Never>?
        var cancelled = false
        for await batch in client.image(req) {
            for e in batch.items {
                switch e {
                case .media(.imageProgress(let p)):
                    if r.firstPreview == nil { r.firstPreview = secs(batch.receivedAt - sent) }
                    r.progress.append(p)
                    if p.sdServerPID > 0 { r.sdPID = p.sdServerPID; pids.insert(p.sdServerPID) }
                    if let c = cancelAtStep, p.step >= c, !cancelled {
                        cancelled = true
                        client.cancel(req.requestID)
                    }
                case .media(.scheduler(let n)):
                    r.notes.append(n)
                    if n.action == "sdStarted", let p = n.detail["pid"].flatMap(Int32.init) { r.sdPID = p; pids.insert(p) }
                case .media(.imageResult(let res)):
                    r.final = secs(batch.receivedAt - sent)
                    r.result = res
                    if let slot = chatAfter {
                        let t0 = batch.receivedAt
                        chatTask = Task {
                            await probeChat(client, slot, from: t0)
                        }
                    }
                case .engine(.error(let err)): r.error = err.description
                default: break
                }
            }
        }
        r.chatAtResult = await chatTask?.value
        return r
    }

    static func probeChat(_ client: EngineClient, _ slot: ModelSlot, from t0: ContinuousClock.Instant) async -> ChatProbe {
        var c = ChatProbe()
        let req = ChatRequest(
            modelSlot: slot, messages: [ChatMessage(role: .user, content: "Name one color of the sky. One word.")],
            sampling: Sampling(temperature: 0, maxTokens: 8))
        for await b in client.chatBatches(req) {
            if b.tokens > 0 {
                if c.ttft == nil { c.ttft = secs(b.receivedAt - t0) }
                c.tokens += b.tokens
            }
            for e in b.items {
                switch e {
                case .engine(.textDelta(let s)): c.text += s
                case .lifecycle(.loadState(let st)): c.loadStates.append(st.rawValue)
                case .engine(.usage(let u)): c.loadTime = u.loadTime
                case .engine(.error(let err)): c.error = err.description
                default: break
                }
            }
        }
        return c
    }

    static func imageRequest(_ a: Args, _ prompts: [(String, Int64)], i: Int, tag: String, restore: ModelSlot? = nil) -> ImageRequest {
        let res = a.int("res", 768)
        let quant = a.opts["quant"] ?? "q4"
        let (p, seed) = prompts[i % max(1, prompts.count)]
        let out = URL(fileURLWithPath: benchOutDir(a)).appendingPathComponent("\(tag)-\(quant)-\(res)-\(String(format: "%02d", i)).png").path
        return ImageRequest(
            model: DevModels.imageSet(quant, res: res), prompt: p, width: res, height: res, steps: a.int("steps", 4), seed: seed,
            preview: a.opts["preview"] ?? "proj", outputPath: (out as NSString).standardizingPath, restoreChat: restore,
            safety: benchSafety)
    }

    /// M4.T04: every bench image passes the ChildSafetyCheck gate too (none ⇒ `safetyMissing`, nothing written).
    /// M4 review P1-1 (D-006: no launch argument changes the gate): Debug benches use the dev detector files; a Release
    /// build only ever uses the detectors the SIGNED catalog pins (sha256 from the verified catalog, files from this
    /// container's install views, re-verified by the helper before loading) — never hashes of whatever files are there.
    static let benchSafety: SafetyManifest? = {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        return SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot)
        #else
        let m = signedCatalogSafety()
        if m == nil { say("bench: the signed catalog's ChildSafetyCheck detectors are not installed; every output is withheld") }
        return m
        #endif
    }()

    #if !DEBUG
    /// The `csam_check` detectors of the last good verified catalog (cache, else the bundled baseline) in this
    /// container's install views; nil when the catalog does not verify or a file is absent.
    static func signedCatalogSafety() -> SafetyManifest? {
        let container = AppDatabase.containerURL()
        let store = CatalogStore(url: CatalogStore.endpoint(), cacheDirectory: container.appending(path: "Catalog"), database: nil)
        guard let catalog = store.catalog else { return nil }
        var pins: [String: String] = [:]
        for (key, file) in SafetyManifestResolver.files {
            guard let f = catalog.models[key]?.files.first(where: { $0.path == file }) else { return nil }
            pins[key] = f.sha256
        }
        return SafetyManifestResolver.resolve(modelsRoot: ModelsDirectory.default(container: container).installs, pinned: pins)
    }
    #endif

    /// Where the bench's gated PNGs go. Debug: `--out-dir` (default build/at/AT-M0-06/out). Release (M4 review P1-1):
    /// always the app's own media cache (`~/Library/Caches/AntiChat/xfer/bench`), whatever `--out-dir` says; the raw
    /// rows carry each written path.
    static func benchOutDir(_ a: Args) -> String {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        return a.opts["out-dir"] ?? "build/at/AT-M0-06/out"
        #else
        return MediaJobQueue.defaultXferRoot().appendingPathComponent("bench", isDirectory: true).path
        #endif
    }

    static func imageRow(_ base: [String: Any], _ a: Args, run i: Int, _ r: ImageRun, peak: UInt64) -> [String: Any] {
        var o = base
        o["run"] = i
        o["quant"] = a.opts["quant"] ?? "q4"
        o["res"] = a.int("res", 768)
        o["steps"] = a.int("steps", 4)
        o["final_s"] = r.final ?? -1
        o["first_step_s"] = r.firstPreview ?? -1
        o["first_preview_s"] = r.firstPreview ?? -1  // alias of first_step_s (rows before M9.T05 named it so)
        o["preview_count"] = r.progress.count
        o["preview_steps"] = r.progress.map { "\($0.pass):\($0.step)" }.joined(separator: ",")
        o["peak_footprint_bytes"] = peak
        o["sd_pid"] = r.sdPID
        if let res = r.result {
            o["status"] = res.status
            o["sha256"] = res.sha256
            o["width"] = res.width
            o["height"] = res.height
            o["png_bytes"] = res.bytes
            o["path"] = res.path
            for (k, v) in res.metrics { o["h_\(k)"] = v }
            // M9.T05 / D-006: a timed image counts only with the real ChildSafetyCheck on its output. A completed result
            // without exactly one final gate check would mean the measured path skipped the gate: stop the bench.
            if res.status == "completed" {
                precondition(res.metrics["gate_result_checks"] == 1,
                             "D-006: completed bench image without exactly one ChildSafetyCheck result check (\(res.metrics))")
            }
            o["gate_evidenced"] = (res.metrics["gate_result_checks"] ?? 0) >= 1
        }
        o["notes"] = r.notes.map { n in
            (["action": n.action, "model": n.model, "seconds": n.seconds] as [String: Any]).merging(n.detail.mapValues { $0 as Any }) { $1 }
        }
        if let e = r.error { o["error"] = e }
        return o
    }

    static func sampler(_ ack: HelloAck, _ pids: PIDSet) -> FootprintSampler {
        let s = FootprintSampler()
        let me = getpid()
        s.start { [ack] in [me, ack.helperPID] + pids.all }
        return s
    }

    // MARK: image (P1/P2)

    static func image(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let ps = try prompts(a)
        let pids = PIDSet()
        // Warm: loads sd-server and pays the first-job lazy weight load (recorded, not counted).
        let warm = await runImage(client, imageRequest(a, ps, i: 49, tag: "warm"), pids: pids)
        if let e = warm.error { throw NSError(domain: "bench", code: 4, userInfo: [NSLocalizedDescriptionKey: "warm image: \(e)"]) }
        var w = imageRow(base, a, run: -1, warm, peak: 0)
        w["warm"] = true
        raw.write(w)
        say(String(format: "warm: final %.2fs first step %.2fs (cold sd-server load included)", warm.final ?? -1, warm.firstPreview ?? -1))
        for i in 0..<a.int("runs", 20) {
            let s = sampler(ack, pids)
            let r = await runImage(client, imageRequest(a, ps, i: i, tag: "img"), pids: pids)
            let peak = s.stop()
            raw.write(imageRow(base, a, run: i, r, peak: peak))
            say(String(format: "image %d: final %.2fs first step %.2fs previews %d peak %.2f GB %@", i, r.final ?? -1, r.firstPreview ?? -1, r.progress.count, Double(peak) / 1e9, r.error ?? ""))
        }
    }

    // MARK: handoff (NFR-M3 at the T1 cap)

    static func handoff(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let ps = try prompts(a)
        let slot = DevModels.slot(a.opts["model"] ?? "chat-9b-q4")
        let pids = PIDSet()
        for i in 0..<a.int("runs", 20) {
            // Chat model resident and used (one short answer), like a conversation before "draw …".
            for await _ in client.warmupBatches(slot) {}
            let pre = await probeChat(client, slot, from: .now)
            let s = sampler(ack, pids)
            let r = await runImage(client, imageRequest(a, ps, i: i, tag: "handoff", restore: slot), chatAfter: slot, pids: pids)
            let peak = s.stop()
            var o = imageRow(base, a, run: i, r, peak: peak)
            o["pre_chat_error"] = pre.error ?? "none"
            let ev = r.notes.first { $0.action == "evicted" }
            o["evicted"] = ev != nil
            o["unload_s"] = ev?.seconds ?? -1
            o["unload_call_s"] = ev?.detail["call_s"].flatMap(Double.init) ?? -1
            o["image_unload_s"] = r.notes.first { $0.action == "imageUnloaded" }?.seconds ?? -1
            o["chat_reload_call_s"] = r.notes.first { $0.action == "chatReloaded" }?.seconds ?? -1
            if let c = r.chatAtResult {
                o["queued_chat_first_token_s"] = c.ttft ?? -1
                o["queued_chat_tokens"] = c.tokens
                o["queued_chat_load_states"] = c.loadStates.joined(separator: ",")
                o["queued_chat_error"] = c.error ?? "none"
                o["queued_chat_answered"] = c.tokens > 0 && c.error == nil
            }
            raw.write(o)
            say(String(format: "handoff %d: unload %.3fs, final %.2fs, reload→first token %.3fs, queued answered %@, peak %.2f GB",
                       i, ev?.seconds ?? -1, r.final ?? -1, r.chatAtResult?.ttft ?? -1, "\(r.chatAtResult.map { $0.tokens > 0 && $0.error == nil } ?? false)", Double(peak) / 1e9))
        }
    }

    // MARK: coresident (R-236 at the T2-24 cap)

    static func coresident(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let ps = try prompts(a)
        let slot = DevModels.slot(a.opts["model"] ?? "chat-9b-q4")
        let pids = PIDSet()
        for await _ in client.warmupBatches(slot) {}
        // Warm the image context once (cold sd-server start + lazy weights) without timing it.
        _ = await runImage(client, imageRequest(a, ps, i: 49, tag: "warm"), pids: pids)
        for i in 0..<a.int("runs", 10) {
            let pre = await probeChat(client, slot, from: .now)
            let s = sampler(ack, pids)
            let r = await runImage(client, imageRequest(a, ps, i: i, tag: "cores"), pids: pids)
            let t0 = ContinuousClock.now
            let post = await probeChat(client, slot, from: t0)
            let peak = s.stop()
            var o = imageRow(base, a, run: i, r, peak: peak)
            let kept = r.notes.first { $0.action == "kept" }
            let after = r.notes.first { $0.action == "chatStillResident" }
            o["evicted"] = r.notes.contains { $0.action == "evicted" }
            o["container_before"] = kept?.detail["container"] ?? "?"
            o["container_after"] = after?.detail["container"] ?? "?"
            o["container_unchanged"] = kept != nil && after != nil && kept?.detail["container"] == after?.detail["container"]
            o["pre_chat_error"] = pre.error ?? "none"
            o["next_chat_ttft_s"] = post.ttft ?? -1
            o["next_chat_reloaded"] = !post.loadStates.isEmpty || (post.loadTime ?? 0) > 0
            o["next_chat_error"] = post.error ?? "none"
            raw.write(o)
            say(String(format: "coresident %d: evicted %@ container %@→%@ next TTFT %.3fs peak %.2f GB", i, "\(o["evicted"]!)",
                       kept?.detail["container"] ?? "?", after?.detail["container"] ?? "?", post.ttft ?? -1, Double(peak) / 1e9))
        }
    }

    // MARK: cancel

    static func cancel(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let ps = try prompts(a)
        let pids = PIDSet()
        let step = a.int("cancel-step", 2)
        // A completed warm job first, so sd-server's idle level is its warm idle level.
        _ = await runImage(client, imageRequest(a, ps, i: 49, tag: "warm"), pids: pids)
        for i in 0..<a.int("runs", 10) {
            let s = sampler(ack, pids)
            let r = await runImage(client, imageRequest(a, ps, i: i, tag: "cancel"), cancelAtStep: step, pids: pids)
            let peak = s.stop()
            var o = imageRow(base, a, run: i, r, peak: peak)
            o["cancel_at_step"] = step
            raw.write(o)
            let m = r.result?.metrics ?? [:]
            say(String(format: "cancel %d: status %@ steps after cancel %.0f stop %.2fs mem freed %.2fs (from the cancel)", i,
                       r.result?.status ?? "?", m["steps_after_cancel"] ?? -1, m["cancel_to_stopped_s"] ?? -1, m["cancel_mem_recover_s"] ?? -1))
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
