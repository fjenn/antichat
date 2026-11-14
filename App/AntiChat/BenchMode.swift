// Headless bench mode (M0.T04 step 7): `AntiChat -Bench <cmd> …`. The bundled XPC service is only
// reachable from its containing app, so the benchmark runs AS the app, through the real XPC path.
// Commands (all write one JSON object per run to --raw <file>; tools/perf/report.py aggregates):
//   chat    --model K --tier-cap T --runs N --ctx 1k|4k [--batch 16:8] [--fixtures DIR] [--label L]
//   load    --model K --tier-cap T --runs N            (M1: evict → warmup → ready; [WARM-CACHE])
//   restart --model K --runs N                         (NFR-S4: SIGKILL the helper mid-stream → HelloAck)
//   family  --model K [--image PATH]                   (K-NEW-MOD-5: load + one short generation)
//   voice   --model K --tier-cap T --runs N --input DIR --mode inject|blackhole [--tts kokoro|system]
//           [--simulate-kokoro-failure] [--volume 0]       (M0.T05: one voice turn per utterance, helper-side)
//   voice   --mode live --seconds N                      (M0.T05 step 7 / vq-00 B: helper mic capture, RMS)
//   image | handoff | coresident | cancel              (M0.T06 S-5, BenchMode+Image.swift)
//   video --mode t2v|i2v …                             (M0.T07 S-10, BenchMode+Video.swift)
//   swap    --normal K --evil K --tier-cap T --runs N  (M0.T09 NFR-C7: swap request → first textDelta, both ways)
//   agentic --model K --set FILE.jsonl [--thinking on] (M0.T09: tool calls per task; tools/eval/agentic.py scores)
//   gen     --model K --set FILE.jsonl                 (M0.T09: one answer per prompt for the blind judges)
//   image-turn | read-aloud | transcribe-file           (M9.T05: AT-236 AC3, NFR-V8 / NFR-V11 per tier cap)
//   firstchat --rate 50|10|0 --runs N [--chunk-mb 32] [--test run|disconnect|stall|kill|resume|corrupt]
//                                                      (M0.T10 NFR-M5/D6: download start → first token; resume tests)
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Darwin
import Foundation
import os

enum BenchMode {
    static func runAndExit() -> Never {
        Task.detached {
            let code: Int32
            do {
                try await run(Array(CommandLine.arguments.drop(while: { $0 != "-Bench" }).dropFirst()))
                code = 0
            } catch {
                FileHandle.standardError.write(Data("bench: \(error)\n".utf8))
                code = 1
            }
            exit(code)
        }
        dispatchMain()
    }

    struct Args {
        var cmd = ""
        var opts: [String: String] = [:]
        init(_ a: [String]) {
            cmd = a.first ?? ""
            var i = 1
            while i < a.count {
                if a[i].hasPrefix("--") {
                    let k = String(a[i].dropFirst(2))
                    if i + 1 < a.count, !a[i + 1].hasPrefix("--") {
                        opts[k] = a[i + 1]
                        i += 2
                    } else {
                        opts[k] = "1"
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }
        func int(_ k: String, _ d: Int) -> Int { opts[k].flatMap(Int.init) ?? d }
    }

    static let log = Logger(subsystem: "app.antichat", category: "bench")
    static let signposter = OSSignposter(subsystem: "app.antichat", category: "bench")

    static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func say(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func physFootprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    /// Samples phys_footprint of the app + helper (+ extra pids) every 100 ms; returns the max sum.
    final class FootprintSampler: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: UInt64(0))
        private var task: Task<Void, Never>?
        func start(pids: @escaping @Sendable () -> [pid_t]) {
            lock.withLock { $0 = 0 }
            task = Task.detached { [lock] in
                while !Task.isCancelled {
                    let total = pids().reduce(UInt64(0)) { $0 + BenchMode.physFootprint($1) }
                    lock.withLock { $0 = max($0, total) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        func stop() -> UInt64 {
            task?.cancel()
            return lock.withLock { $0 }
        }
    }

    final class RawWriter {
        let handle: FileHandle?
        init(_ path: String?) {
            guard let path else { handle = nil; return }
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
        func write(_ obj: [String: Any]) {
            // NaN/inf or a non-JSON value would make the row vanish silently (or raise); say so instead.
            guard JSONSerialization.isValidJSONObject(obj),
                  let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
                BenchMode.say("bench: raw row dropped (not valid JSON): \(obj)")
                return
            }
            handle?.write(d)
            handle?.write(Data("\n".utf8))
        }
    }

    static func run(_ argv: [String]) async throws {
        let a = Args(argv)
        if a.cmd == "buildinfo" {  // M9.T05: run.py's build check (no helper needed)
            print(BuildFlavor.json)
            return
        }
        let client = EngineClient(appBuild: "bench")
        // An XPCSession released while active traps (SIGTRAP at exit); cancel it explicitly.
        defer { client.disconnect() }
        let ack = try await client.connect()
        say("helloAck helper=\(ack.helperPID) recommendedMaxWorkingSetSize=\(ack.recommendedMaxWorkingSetSize)")
        let tier = a.opts["tier-cap"] ?? "none"
        // An unknown cap (e.g. "T3" instead of "T3-48") used to fall back to budget 0 = uncapped, silently.
        guard let capB = DevModels.tierB[tier] else {
            throw NSError(domain: "bench", code: 64, userInfo: [NSLocalizedDescriptionKey:
                "unknown --tier-cap \(tier); one of \(DevModels.tierB.keys.sorted().joined(separator: ", "))"])
        }
        let budget = UInt64(capB * 1e9)
        let (bw, bt): (Int, Int) = {
            let p = (a.opts["batch"] ?? "16:8").split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : (16, 8)
        }()
        // fix/t05-video: `-Bench video` runs under the tier rule the app sends for that tier (AppBootstrap: lowTier =
        // tier ≤ T2), so a T3/T4 job preloads the detectors and streams its final check exactly as in the app. Every
        // other bench keeps the old default (lowTier true) until it is re-baselined on its own.
        let lowTier = a.cmd == "video" ? videoLowTier(a, cap: tier) : true
        try await client.setPolicy(SetPolicy(budgetB: budget, batch: BatchPolicy(windowMS: bw, maxTokens: bt), lowTier: lowTier))
        let raw = RawWriter(a.opts["raw"])
        var base: [String: Any] = [
            "cmd": a.cmd, "model": a.opts["model"] ?? "", "tier": tier, "label": a.opts["label"] ?? "xpc",
            "batch": "\(bw):\(bt)", "helper_pid": ack.helperPID, "recommended_max_working_set": ack.recommendedMaxWorkingSetSize,
        ]
        if a.cmd == "video" { base["low_tier"] = lowTier }
        switch a.cmd {
        case "chat": try await chat(a, client: client, ack: ack, raw: raw, base: base)
        case "load": try await load(a, client: client, ack: ack, raw: raw, base: base)
        case "restart": try await restart(a, client: client, raw: raw, base: base)
        case "family": try await family(a, client: client, raw: raw, base: base)
        case "voice": try await voice(a, client: client, ack: ack, raw: raw, base: base)
        case "dictation": try await dictation(a, client: client, raw: raw, base: base)  // M3.T03 V6/V7
        case "dictation-warm": try await dictationWarm(a, client: client, raw: raw, base: base)  // M3.T03 V10
        case "voice-session": try await voiceSession(a, client: client, raw: raw, base: base)  // M3.T11 V1/V2/V283
        case "voice-approval": try await voiceApproval(a, client: client, raw: raw, base: base)  // M3 review P1-5
        case "aec": try await aec(a, client: client, raw: raw, base: base)  // M3.T12 AT-280 AC1/AC3 (live, speakers)
        case "image": try await image(a, client: client, ack: ack, raw: raw, base: base)
        case "handoff": try await handoff(a, client: client, ack: ack, raw: raw, base: base)
        case "coresident": try await coresident(a, client: client, ack: ack, raw: raw, base: base)
        case "cancel": try await cancel(a, client: client, ack: ack, raw: raw, base: base)
        case "video": try await video(a, client: client, ack: ack, raw: raw, base: base)
        case "swap": try await swap(a, client: client, ack: ack, raw: raw, base: base)
        case "agentic": try await agentic(a, client: client, raw: raw, base: base)
        case "gen": try await gen(a, client: client, raw: raw, base: base)
        case "firstchat": try await firstChat(a, client: client, raw: raw, base: base)
        case "memory": try await memory(a, client: client, raw: raw, base: base)  // M8.T02 AT-242
        case "image-turn": try await imageTurn(a, client: client, raw: raw, base: base)  // M9.T05 AT-236 AC3
        case "read-aloud": try await readAloud(a, client: client, raw: raw, base: base)  // M9.T05 NFR-V8 per tier
        case "transcribe-file": try await transcribeFile(a, client: client, raw: raw, base: base)  // M9.T05 NFR-V11 per tier
        case "hello": raw.write(base)
        default: throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown cmd \(a.cmd)"])
        }
    }

    static func fixturesDir(_ a: Args) -> URL {
        URL(fileURLWithPath: a.opts["fixtures"] ?? "fixtures")
    }

    static func messages(_ a: Args) throws -> (msgs: [ChatMessage], maxTokens: Int) {
        let f = fixturesDir(a).appendingPathComponent("prompts")
        let system = try String(contentsOf: f.appendingPathComponent("bench-system.txt"), encoding: .utf8)
        if a.opts["ctx"] == "4k" {
            let doc = try String(contentsOf: f.appendingPathComponent("bench-4k-doc.txt"), encoding: .utf8)
            return ([ChatMessage(role: .user, content: doc + "\n\nIn one sentence, what is this document about?")], 16)
        }
        let user = try String(contentsOf: f.appendingPathComponent("bench-300tok.txt"), encoding: .utf8)
        return ([ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)], 256)
    }

    struct RunResult {
        var ttft: Double?
        var tokens = 0
        var tFirst: ContinuousClock.Instant?
        var tLast: ContinuousClock.Instant?
        var deltaMessages = 0
        var messages = 0
        var usage: Usage?
        var error: String?
        var text = ""
        var reasoningChars = 0
        var toolCalls: [[String: String]] = []
        var finish: String?
    }

    static func stream(_ client: EngineClient, _ req: ChatRequest, killAfterFirst: (() -> Void)? = nil) async -> RunResult {
        var r = RunResult()
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("ttft", id: id)
        let sent = ContinuousClock.now
        var ended = false
        for await batch in client.chatBatches(req) {
            r.messages += 1
            let n = batch.tokens
            if n > 0 {
                if r.tFirst == nil {
                    r.tFirst = batch.receivedAt
                    r.ttft = secs(batch.receivedAt - sent)
                    signposter.endInterval("ttft", state)
                    killAfterFirst?()
                }
                r.tLast = batch.receivedAt
                r.tokens += n
                r.deltaMessages += 1
            }
            for e in batch.events {
                switch e {
                case .usage(let u): r.usage = u
                case .error(let err): r.error = err.description; ended = true
                case .textDelta(let s): r.text += s
                case .reasoningDelta(let s): r.reasoningChars += s.count
                case .toolCallDone(let id, let name, let args): r.toolCalls.append(["id": id, "name": name, "arguments": args])
                case .done(let reason): r.finish = reason.rawValue; ended = true
                default: break
                }
            }
            if ended { break }
        }
        if r.tFirst == nil { signposter.endInterval("ttft", state) }
        return r
    }

    static func chat(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "chat-0.8b")
        let (msgs, maxTokens) = try messages(a)
        // Warm model + one discarded run (M0.T04 step 7 "warm model").
        for await _ in client.warmupBatches(slot) {}
        let warm = await stream(client, ChatRequest(modelSlot: slot, messages: msgs, sampling: Sampling(temperature: 0.7, maxTokens: 32, seed: 1)))
        if let e = warm.error { throw NSError(domain: "bench", code: 3, userInfo: [NSLocalizedDescriptionKey: "warm run: \(e)"]) }
        let helper = ack.helperPID
        let me = getpid()
        let sampler = FootprintSampler()
        for i in 0..<a.int("runs", 20) {
            sampler.start { [me, helper] in [me, helper] }
            let req = ChatRequest(modelSlot: slot, messages: msgs, sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: maxTokens, seed: UInt64(100 + i)))
            let r = await stream(client, req)
            let peak = sampler.stop()
            var o = base
            o["run"] = i
            o["ctx"] = a.opts["ctx"] ?? "1k"
            o["ttft_s"] = r.ttft ?? -1
            o["tokens"] = r.tokens
            if let f = r.tFirst, let l = r.tLast, r.tokens > 1 {
                let span = secs(l - f)
                o["decode_tps"] = span > 0 ? Double(r.tokens - 1) / span : -1
                o["msgs_per_s"] = span > 0 ? Double(r.deltaMessages - 1) / span : -1
                o["stream_s"] = span
            }
            o["messages"] = r.messages
            o["peak_footprint_bytes"] = peak
            if let u = r.usage {
                o["prompt_tokens"] = u.promptTokens
                o["prompt_time_s"] = u.promptTime
                o["prefill_tps"] = u.promptTime > 0 ? Double(u.promptTokens) / u.promptTime : -1
                o["engine_generated"] = u.completionTokens
                o["engine_decode_tps"] = u.generateTime > 0 ? Double(u.completionTokens) / u.generateTime : -1
                o["gpu_peak_bytes"] = u.gpuPeakBytes
                o["mtl_allocated_bytes"] = u.mtlAllocatedBytes
                o["stop_reason"] = r.finish ?? ""
            }
            if let e = r.error { o["error"] = e }
            raw.write(o)
            say(String(format: "run %d ttft=%.3fs tokens=%d decode=%.1f tok/s msgs/s=%.1f", i, r.ttft ?? -1, r.tokens, (o["decode_tps"] as? Double) ?? -1, (o["msgs_per_s"] as? Double) ?? -1))
        }
    }

    static func load(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "chat-0.8b")
        let sampler = FootprintSampler()
        for i in 0..<a.int("runs", 10) {
            for await _ in client.evict() {}
            sampler.start { [ack] in [getpid(), ack.helperPID] }
            let id = signposter.makeSignpostID()
            let st = signposter.beginInterval("modelLoad", id: id)
            let t0 = ContinuousClock.now
            var engineLoad: Double?
            var err: String?
            for await b in client.warmupBatches(slot) {
                for e in b.events {
                    if case .usage(let u) = e { engineLoad = u.loadTime }
                    if case .error(let x) = e { err = x.description }
                }
            }
            let warmupWall = secs(ContinuousClock.now - t0)
            // NFR-M1 is "SSD → first token possible": MLX maps weights lazily, so the load call alone
            // under-reports. Count through the first generated token of a 1-token request.
            let first = await stream(client, ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "Hi")], sampling: Sampling(temperature: 0, maxTokens: 1)))
            if let e = first.error { err = err ?? e }
            let wall = secs(ContinuousClock.now - t0)
            signposter.endInterval("modelLoad", st)
            var o = base
            o["run"] = i
            o["load_s"] = wall
            o["load_call_s"] = warmupWall
            o["engine_load_s"] = engineLoad ?? -1
            o["peak_footprint_bytes"] = sampler.stop()
            o["cache"] = "[WARM-CACHE]"
            if let err { o["error"] = err }
            raw.write(o)
            say(String(format: "load %d %.3fs (engine %.3fs)", i, wall, engineLoad ?? -1))
        }
    }

    static func llamaPIDs() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "Contents/Helpers/llama-server"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.split(separator: "\n").compactMap { pid_t($0) }
    }

    static func restart(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "chat-0.8b")
        let prompt = [ChatMessage(role: .user, content: "Write 300 words about tides.")]
        for i in 0..<a.int("runs", 10) {
            var ack = try await client.connect()
            for await _ in client.warmupBatches(slot) {}
            if let w = a.opts["alive-before-kill"].flatMap(Double.init) {
                // Let the helper live this long before the kill (launchd respawn-throttle check).
                try await Task.sleep(for: .seconds(w))
            }
            let llamaBefore = llamaPIDs()
            let killedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
            let orphanGoneAt = OSAllocatedUnfairLock<Double>(initialState: -1)
            let helper = ack.helperPID
            var orphanTask: Task<Void, Never>?
            let r = await stream(client, ChatRequest(modelSlot: slot, messages: prompt, sampling: Sampling(maxTokens: 2048))) {
                let t = ContinuousClock.now
                killedAt.withLock { $0 = t }
                kill(helper, SIGKILL)  // same as `pkill -9 -f AntiChatEngine`
                // Orphan check (watchdog) runs concurrently from the kill instant.
                orphanTask = Task.detached {
                    if llamaBefore.isEmpty { orphanGoneAt.withLock { $0 = 0 }; return }
                    while BenchMode.secs(ContinuousClock.now - t) < 15 {
                        if llamaBefore.allSatisfy({ kill($0, 0) != 0 }) {
                            let d = BenchMode.secs(ContinuousClock.now - t)
                            orphanGoneAt.withLock { $0 = d }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            guard let t0 = killedAt.withLock({ $0 }) else {
                raw.write(base.merging(["run": i, "error": "no token before kill: \(r.error ?? "")"]) { $1 })
                continue
            }
            let invalidatedAfter = secs(ContinuousClock.now - t0)
            var reconnected: Double = -1
            var attempts: [String] = []
            let attemptTimeout = Double(a.opts["attempt-timeout"] ?? "10") ?? 10
            while secs(ContinuousClock.now - t0) < 30 {
                let ta = ContinuousClock.now
                do {
                    ack = try await client.connect(timeout: .seconds(attemptTimeout))
                    reconnected = secs(ContinuousClock.now - t0)
                    attempts.append(String(format: "ok@%.3f", secs(ContinuousClock.now - ta)))
                    break
                } catch {
                    attempts.append(String(format: "%@@%.3f", "\(error)", secs(ContinuousClock.now - ta)))
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            await orphanTask?.value
            let orphanGone = orphanGoneAt.withLock { $0 }
            var o = base
            o["run"] = i
            o["killed_pid"] = helper
            o["new_pid"] = ack.helperPID
            o["restart_s"] = reconnected
            o["connect_attempts"] = attempts
            o["invalidated_after_s"] = invalidatedAfter
            o["stream_ended_with"] = r.error ?? "none"
            o["llama_pids_before"] = llamaBefore.map { Int($0) }
            o["orphan_gone_s"] = orphanGone
            raw.write(o)
            say(String(format: "restart %d: HelloAck after %.3fs (pid %d → %d), llama orphans gone after %.3fs", i, reconnected, helper, ack.helperPID, orphanGone))
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    static func family(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "chat-0.8b")
        var o = base
        o["engine"] = slot.engine.rawValue
        o["vision"] = slot.vision
        var loadErr: String?
        let t0 = ContinuousClock.now
        for await b in client.warmupBatches(slot) {
            for e in b.events { if case .error(let x) = e { loadErr = x.description } }
        }
        o["load_s"] = secs(ContinuousClock.now - t0)
        o["loads"] = loadErr == nil
        if let loadErr {
            o["error"] = loadErr
            raw.write(o)
            say("family \(slot.key): load failed \(loadErr)")
            return
        }
        let images = a.opts["image"].map { [$0] } ?? []
        let question = a.opts["question"] ?? (images.isEmpty ? "Say hello in five words." : "What text is in this image? Answer briefly.")
        let r = await stream(
            client, ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: question, imagePaths: images)], sampling: Sampling(temperature: 0, maxTokens: 64)))
        o["generates"] = r.tokens > 0 && r.error == nil
        o["tokens"] = r.tokens
        o["text"] = String(r.text.prefix(300))
        o["image"] = images.first ?? ""
        if let e = r.error { o["error"] = e }
        raw.write(o)
        if let hold = a.opts["hold"].flatMap(Double.init) {
            // Keep the engine (and llama-server) alive for external checks (AT-M0-04 lsof).
            say("holding \(hold)s")
            try await Task.sleep(for: .seconds(hold))
        }
        say("family \(slot.key): tokens=\(r.tokens) err=\(r.error ?? "-") text=\(r.text.prefix(120))")
    }

    // MARK: voice (M0.T05)

    static let voiceSystemPrompt =
        "You are a friendly voice assistant on the user's Mac. The user's words come from speech recognition. "
        + "Reply in one or two short spoken sentences, plain text, no lists or markdown."

    static func voiceModels() -> VoiceModelPaths {
        let d = DevModels.modelsDir
        return VoiceModelPaths(
            stt: d.appendingPathComponent("stt").path, vad: d.appendingPathComponent("vad-files").path,
            turn: d.appendingPathComponent("turn").path, tts: d.appendingPathComponent("tts").path)
    }

    /// The shortest `n` utterances between 2 and 6 s from `<dir>/transcripts.tsv` (M0.T05 step 4).
    static func voiceUtterances(_ dir: URL, n: Int) throws -> [(id: String, seconds: Double, text: String)] {
        let tsv = try String(contentsOf: dir.appendingPathComponent("transcripts.tsv"), encoding: .utf8)
        let rows = tsv.split(separator: "\n").dropFirst().compactMap { line -> (String, Double, String)? in
            let c = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard c.count == 3, let d = Double(c[1]), d >= 2, d <= 6 else { return nil }
            return (c[0], d, c[2])
        }
        return Array(rows.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.prefix(n)).map { (id: $0.0, seconds: $0.1, text: $0.2) }
    }

    static func runVoice(_ client: EngineClient, _ req: VoiceRequest) async -> VoiceTurnReport? {
        for await b in client.voice(req) {
            for e in b.media {
                if case .voiceReport(let r) = e { return r }
            }
            for e in b.events {
                if case .error(let x) = e { say("voice error: \(x)") }
            }
        }
        return nil
    }

    static func voice(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let mode = VoiceInputMode(rawValue: a.opts["mode"] ?? "inject") ?? .inject
        let tts = VoiceTTSEngine(rawValue: a.opts["tts"] ?? "kokoro") ?? .kokoro
        let slot = DevModels.slot(a.opts["model"] ?? "chat-2b")
        let models = voiceModels()
        var b = base
        b["mode"] = mode.rawValue
        b["mode_label"] = mode == .inject ? "[IN-PIPELINE]" : mode.rawValue
        b["tts_requested"] = tts.rawValue
        b["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        if mode == .live {
            let req = VoiceRequest(mode: .live, liveSeconds: Double(a.opts["seconds"] ?? "3") ?? 3, models: models, chat: slot, systemPrompt: "")
            guard let r = await runVoice(client, req) else { throw NSError(domain: "bench", code: 4, userInfo: [NSLocalizedDescriptionKey: "no voice report"]) }
            var o = b
            o["live_rms_dbfs"] = r.liveRMSdBFS.map { $0.isFinite ? $0 : -200 } ?? -200
            o["live_samples"] = r.liveFrames ?? 0
            o["live_callbacks"] = r.stageMillis["callbacks"] ?? 0
            o["microphone"] = r.liveMicrophone ?? ""
            if let e = r.error { o["error"] = e }
            raw.write(o)
            say(String(format: "live capture in helper %d: %d samples, RMS %.1f dBFS, mic %@ %@", ack.helperPID, r.liveFrames ?? 0, r.liveRMSdBFS ?? -200, r.liveMicrophone ?? "?", r.error ?? ""))
            return
        }
        let dir = URL(fileURLWithPath: a.opts["input"] ?? "fixtures/audio/librispeech-test-clean-200")
        let utts = try voiceUtterances(dir, n: a.int("runs", 20))
        guard !utts.isEmpty else { throw NSError(domain: "bench", code: 5, userInfo: [NSLocalizedDescriptionKey: "no 2–6 s utterances in \(dir.path)"]) }
        func request(_ id: String, warm: Bool = false) -> VoiceRequest {
            VoiceRequest(
                mode: mode, inputPath: dir.appendingPathComponent("\(id).flac").path, models: models, chat: slot,
                systemPrompt: voiceSystemPrompt, maxTokens: a.int("max-tokens", 80), tts: tts,
                simulateKokoroFailure: a.opts["simulate-kokoro-failure"] == "1",
                outputVolume: Float(a.opts["volume"] ?? "0") ?? 0, warmup: warm)
        }
        // Load the full resident voice set + one discarded turn (compiled kernels, ANE programs).
        let sampler = FootprintSampler()
        let helper = ack.helperPID
        let me = getpid()
        sampler.start { [me, helper] in [me, helper] }
        let tw = ContinuousClock.now
        let warm = await runVoice(client, request(utts[0].id, warm: true))
        let warmPeak = sampler.stop()
        say(String(format: "warm turn %.1fs: %@ → %@ (tts %@ %@)", secs(ContinuousClock.now - tw), warm?.transcript ?? "-", warm?.reply ?? "-", warm?.ttsUsed.rawValue ?? "-", warm?.error ?? ""))
        if let e = warm?.error { throw NSError(domain: "bench", code: 6, userInfo: [NSLocalizedDescriptionKey: "warm voice turn: \(e)"]) }
        var o = b
        o["kind"] = "warm"
        o["peak_footprint_bytes"] = warmPeak
        raw.write(o)
        for (i, u) in utts.enumerated() {
            sampler.start { [me, helper] in [me, helper] }
            let r = await runVoice(client, request(u.id))
            let peak = sampler.stop()
            var o = b
            o["kind"] = "turn"
            o["run"] = i
            o["utterance"] = u.id
            o["utterance_s"] = u.seconds
            o["reference"] = u.text
            o["peak_footprint_bytes"] = peak
            if let r {
                o["v1_s"] = r.v1 ?? -1
                o["v1_waveform_s"] = (r.firstOutputBuffer != nil && r.waveformEndOfSpeech != nil) ? r.firstOutputBuffer! - r.waveformEndOfSpeech! : -1
                for (k, v) in r.stageMillis { o["stage_\(k)_ms"] = v }
                o["transcript"] = r.transcript
                o["reply"] = String(r.reply.prefix(400))
                o["first_sentence"] = r.firstSentenceText
                o["turn_end_reason"] = r.turnEndReason ?? ""
                o["smart_turn_p"] = r.smartTurnProbability.map { Double($0) } ?? -1
                o["tts_used"] = r.ttsUsed.rawValue
                o["kokoro_error"] = r.kokoroError ?? ""
                o["mtl_allocated_bytes"] = r.mtlAllocatedBytes
                o["gpu_peak_bytes"] = r.gpuPeakBytes
                if let e = r.error { o["error"] = e }
                say(String(format: "turn %d %@ (%.2fs): V1 %.3fs [ep %.0f stt %.0f ttft %.0f clause %.0f tts %.0f out %.1f ms] %@ | %@", i, u.id, u.seconds, r.v1 ?? -1,
                    r.stageMillis["endpointing"] ?? -1, r.stageMillis["stt_final"] ?? -1, r.stageMillis["llm_ttft"] ?? -1,
                    r.stageMillis["first_clause"] ?? -1, r.stageMillis["tts_first_chunk"] ?? -1, r.stageMillis["audio_out"] ?? -1,
                    r.transcript, r.error ?? r.firstSentenceText))
            } else {
                o["error"] = "no report"
            }
            raw.write(o)
        }
    }
}

// MARK: - M0.T09 (S-11): Evil swap, tool calls, quality-smoke generations

extension BenchMode {
    /// Reads a JSONL fixture (one object per line, blank lines skipped).
    static func jsonl(_ path: String) throws -> [[String: Any]] {
        let s = try String(contentsOfFile: path, encoding: .utf8)
        return try s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            guard let o = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw NSError(domain: "bench", code: 4, userInfo: [NSLocalizedDescriptionKey: "bad jsonl line in \(path)"])
            }
            return o
        }
    }

    static func chatMessages(_ arr: Any?) -> [ChatMessage] {
        ((arr as? [[String: Any]]) ?? []).map {
            ChatMessage(
                role: ChatMessage.Role(rawValue: $0["role"] as? String ?? "user") ?? .user, content: $0["content"] as? String ?? "",
                imagePaths: $0["images"] as? [String] ?? [])
        }
    }

    /// NFR-C7 at a tier cap (M0.T09 step 2): Normal resident → "new Evil chat" request → the scheduler
    /// evicts MLX (T1 cannot hold both) → llama-server router loads the Evil GGUF (+ mmproj) → first
    /// textDelta; then the reverse swap. Clock = request send → first token, measured in the app.
    static func swap(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let normal = DevModels.slot(a.opts["normal"] ?? "chat-9b-q4")
        let evil = DevModels.slot(a.opts["evil"] ?? "llama:evil-9b")
        let prompt = [ChatMessage(role: .user, content: a.opts["prompt"] ?? "Write one short sentence about autumn leaves.")]
        let sampler = FootprintSampler()
        let helper = ack.helperPID
        let me = getpid()
        // Prime both paths once (Metal pipeline caches, page cache) and leave Normal resident.
        for s in [evil, normal] {
            let r = await stream(client, ChatRequest(modelSlot: s, messages: prompt, sampling: Sampling(temperature: 0, maxTokens: 4)))
            if let e = r.error { throw NSError(domain: "bench", code: 5, userInfo: [NSLocalizedDescriptionKey: "prime \(s.key): \(e)"]) }
        }
        for i in 0..<a.int("runs", 20) {
            for (dir, target) in [("normal->evil", evil), ("evil->normal", normal)] {
                sampler.start { [me, helper] in [me, helper] + BenchMode.llamaPIDs() }
                let id = signposter.makeSignpostID()
                let st = signposter.beginInterval("swap", id: id)
                let r = await stream(
                    client, ChatRequest(modelSlot: target, messages: prompt, sampling: Sampling(temperature: 0.7, maxTokens: 8, seed: UInt64(i))))
                signposter.endInterval("swap", st)
                var o = base
                o["run"] = i
                o["direction"] = dir
                o["model"] = target.key
                o["engine"] = target.engine.rawValue
                o["swap_s"] = r.ttft ?? -1
                o["load_s"] = r.usage?.loadTime ?? -1
                o["prompt_time_s"] = r.usage?.promptTime ?? -1
                o["tokens"] = r.tokens
                o["peak_footprint_bytes"] = sampler.stop()
                o["llama_pids_after"] = llamaPIDs().map { Int($0) }
                if let e = r.error { o["error"] = e }
                raw.write(o)
                say(String(format: "swap %d %@ %.3fs (load %.3fs) tokens=%d", i, dir, r.ttft ?? -1, r.usage?.loadTime ?? -1, r.tokens))
            }
        }
    }

    /// Tool-call bench (M0.T09 step 3): each task = messages + offered tools (OpenAI schema); records every
    /// completed tool call. Validity is scored offline by tools/eval/agentic.py.
    static func agentic(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "llama:evil-9b")
        let tasks = try jsonl(a.opts["set"] ?? "fixtures/prompts/agentic-30.jsonl")
        let thinking = a.opts["thinking"] == "on"
        for await _ in client.warmupBatches(slot) {}
        for t in tasks {
            let tools = try JSONSerialization.data(withJSONObject: t["tools"] ?? [])
            let req = ChatRequest(
                modelSlot: slot, messages: chatMessages(t["messages"]), tools: ToolSchema.fromOpenAI(String(decoding: tools, as: UTF8.self)),
                reasoning: ReasoningOptions(on: thinking), sampling: Sampling(temperature: 0, topP: 1, maxTokens: thinking ? 4096 : 1024, seed: 7))
            let t0 = ContinuousClock.now
            let r = await stream(client, req)
            var o = base
            o["id"] = t["id"] ?? ""
            o["model"] = slot.key
            o["thinking"] = thinking
            o["tool_calls"] = r.toolCalls
            o["text"] = String(r.text.prefix(600))
            o["reasoning_chars"] = r.reasoningChars
            o["wall_s"] = secs(ContinuousClock.now - t0)
            if let e = r.error { o["error"] = e }
            raw.write(o)
            say("agentic \(t["id"] ?? "?") calls=\(r.toolCalls.map { $0["name"] ?? "" }) err=\(r.error ?? "-")")
        }
    }

    /// One answer per prompt (M0.T09 step 5, quality smoke; thinking off, fixed seed).
    static func gen(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "llama:evil-9b")
        let items = try jsonl(a.opts["set"] ?? "fixtures/prompts/consumer-60.jsonl")
        for await _ in client.warmupBatches(slot) {}
        for it in items {
            let msgs = it["messages"] != nil ? chatMessages(it["messages"]) : [ChatMessage(role: .user, content: it["prompt"] as? String ?? "")]
            let r = await stream(
                client,
                ChatRequest(modelSlot: slot, messages: msgs, sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: a.int("max-tokens", 700), seed: 11)))
            var o = base
            o["id"] = it["id"] ?? ""
            o["model"] = slot.key
            o["text"] = r.text
            o["tokens"] = r.tokens
            if let e = r.error { o["error"] = e }
            raw.write(o)
            say("gen \(it["id"] ?? "?") tokens=\(r.tokens) err=\(r.error ?? "-")")
        }
    }
}

// MARK: - M0.T10 (S-12): first-chat starter path

extension BenchMode {
    static let starterRepo = "mlx-community/Qwen3.5-0.8B-MLX-4bit"
    static let starterRevision = "5d894f8cc4ef3e6c88537bf3746ed262f549da6a"

    /// Exclusive flock on the one-GPU-job lock (/tmp/antichat-gpu.lock, the same lock `lockf` takes). Returns the fd
    /// and the seconds spent waiting, which the first-chat clock excludes.
    static func gpuLock() -> (Int32, Double) {
        let t0 = ContinuousClock.now
        let fd = open("/tmp/antichat-gpu.lock", O_CREAT | O_RDWR, 0o666)
        if fd >= 0 { flock(fd, LOCK_EX) }
        return (fd, secs(ContinuousClock.now - t0))
    }

    static func writeCounter(_ path: String?, _ v: Int64) {
        guard let path else { return }
        try? Data("\(v)\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// M0.T10 steps 1, 3 and 4, now through M2.T08's DownloadCoordinator (the M0 SpikeDownloader is gone). Clock:
    /// download start (stand-in for "Continue on the packs screen") → first streamed token. Files = the bundled catalog's
    /// `chat-0.8b`. Tests: `run` (clear the store, full path), `disconnect` (at ~40 % every job is paused — its lanes
    /// cancelled — then resumed from the bitmaps), `stall` (at ~40 % zero bandwidth for 10 s), `kill` (at ~40 % the app
    /// SIGKILLs itself after saving its byte counter to --counter-file), `resume` (relaunch after `kill`), `corrupt`
    /// (after a full download one byte of the big blob is flipped; the re-hash must catch it and re-fetch only that file).
    static func firstChat(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let rate = Double(a.opts["rate"] ?? "0") ?? 0
        let test = a.opts["test"] ?? "run"
        let chunkMB = Int64(a.int("chunk-mb", 64))
        let devRoot = DevModels.modelsDir.deletingLastPathComponent()
        let root = devRoot.appendingPathComponent("S12", isDirectory: true)
        let models = ModelsDirectory(root: root)
        let counter = ByteCounter()
        let bucket = rate > 0 ? TokenBucket(mbps: rate) : nil
        guard let catalog = CatalogStore.bundledBaseline().flatMap({ try? ModelCatalog.decode($0.data) }),
              let starter = catalog.models["chat-0.8b"] else { throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "bundled catalog has no chat-0.8b"]) }
        let files = starter.files
        let total = starter.totalBytes
        let big = files.max { $0.size < $1.size }!
        let counterFile = a.opts["counter-file"]
        let prompt = [ChatMessage(role: .user, content: "Hello! In one sentence, what can you help me with?")]
        for i in 0..<a.int("runs", 1) {
            if test != "resume" { try? FileManager.default.removeItem(at: root) }
            try models.create()
            counter.reset()
            let db = try AppDatabase.onDisk(at: root.appendingPathComponent("bench.sqlite"))
            let dl = DownloadCoordinator(models: models, database: db, config: TransferConfig(chunkSize: chunkMB * TransferConfig.mib),
                                         onBytes: { n in bucket?.consume(n); counter.add(n) })
            for await _ in client.evict() {}
            let t0 = ContinuousClock.now
            try await dl.restore()
            var interrupted = ""
            var watcher: Task<Void, Never>?
            if ["disconnect", "stall", "kill"].contains(test) {
                watcher = Task.detached {
                    while counter.total < Int64(Double(total) * 0.4) { try? await Task.sleep(for: .milliseconds(5)) }
                    switch test {
                    case "kill":
                        writeCounter(counterFile, counter.total)
                        say("kill: SIGKILL self at \(counter.total) bytes")
                        kill(getpid(), SIGKILL)
                    case "stall":
                        bucket?.setBlocked(true)
                        try? await Task.sleep(for: .seconds(10))
                        bucket?.setBlocked(false)
                    default:
                        for j in await dl.allJobs where !j.state.isTerminal { await dl.pause(j.id) }
                        try? await Task.sleep(for: .milliseconds(200))
                        for j in await dl.allJobs where j.state == .paused { await dl.resume(j.id) }
                    }
                }
            }
            let jobs = await dl.enqueue(model: starter, pack: "chat")
            if test == "disconnect" { interrupted = "paused+resumed " }
            var failed: [String] = []
            for j in jobs {
                let end = await dl.wait(j.id)
                if end?.state != .done { failed.append("\(j.sha256.prefix(8)):\(end?.errorKey ?? "?")") }
            }
            watcher?.cancel()
            guard failed.isEmpty else { throw NSError(domain: "bench", code: 8, userInfo: [NSLocalizedDescriptionKey: "download failed: \(failed)"]) }
            let blobs = BlobStore(models: models)
            let dir = root.appendingPathComponent("models/chat-starter", isDirectory: true)
            func materialize() throws {
                try? FileManager.default.removeItem(at: dir)
                for f in files { try FilePlacement.symlink.place(blobs.url(f.sha256), at: dir.appendingPathComponent(f.path)) }
            }
            try materialize()
            let downloadS = secs(ContinuousClock.now - t0)
            var received = counter.total
            var prior: Int64 = 0
            if test == "resume", let cf = counterFile, let s = try? String(contentsOfFile: cf, encoding: .utf8) {
                prior = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                received += prior
            }
            var corruptBad: [String] = []
            var corruptRefetch: Int64 = -1
            if test == "corrupt" {
                let blob = blobs.url(big.sha256)
                chmod(blob.path, 0o644)
                let h = try FileHandle(forUpdating: blob)
                try h.seek(toOffset: UInt64(big.size / 2))
                let b = try h.read(upToCount: 1) ?? Data([0])
                try h.seek(toOffset: UInt64(big.size / 2))
                try h.write(contentsOf: Data([b[0] ^ 0xFF]))
                try h.close()
                for f in files where (try? Verify.sha256(blobs.url(f.sha256))) != f.sha256 {
                    corruptBad.append(f.path)
                    try blobs.remove(f.sha256)
                }
                let before = counter.total
                for j in await dl.enqueue(model: starter, pack: "chat") { _ = await dl.wait(j.id) }
                corruptRefetch = counter.total - before
                corruptBad += files.filter { (try? Verify.sha256(blobs.url($0.sha256))) != $0.sha256 }.map { "after-refetch:\($0.path)" }
                try materialize()
            }
            // Load + first token under the GPU lock; the lock wait is excluded from the clock.
            let (fd, waited) = gpuLock()
            let slot = ModelSlot(engine: .mlx, key: "chat-starter-\(i)-\(UUID().uuidString.prefix(6))", path: dir.path, footprintBytes: UInt64(total))
            let r = await stream(client, ChatRequest(modelSlot: slot, messages: prompt, sampling: Sampling(temperature: 0.7, maxTokens: 16, seed: 1)))
            if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
            // Stops at the first streamed token (app-side receipt), minus the GPU-lock wait.
            let firstTokenS = r.tFirst.map { secs($0 - t0) - waited } ?? -1
            var o = base
            o["run"] = i
            o["test"] = test
            o["rate_mbps"] = rate
            o["label"] = rate > 0 ? "[EMULATED]" : "unthrottled"
            o["chunk_mb"] = chunkMB
            o["files"] = files.count
            o["total_bytes"] = total
            o["received_bytes"] = received
            o["prior_bytes"] = prior
            o["refetched_bytes"] = received - total
            o["download_s"] = downloadS
            o["download_to_first_token_s"] = firstTokenS
            o["ttft_after_download_s"] = r.ttft ?? -1
            o["gpu_lock_wait_s"] = waited
            o["interrupted"] = interrupted
            o["verified_files"] = files.count
            o["text"] = String(r.text.prefix(120))
            if test == "corrupt" {
                o["corrupt_detected"] = corruptBad
                o["corrupt_refetch_bytes"] = corruptRefetch
                o["corrupt_file_size"] = big.size
            }
            if let e = r.error { o["error"] = e }
            raw.write(o)
            say(String(format: "firstchat %d %@ rate=%.0f total=%.1fs download=%.1fs refetch=%lld B", i, test, rate,
                       firstTokenS, downloadS, received - total))
            if i + 1 < a.int("runs", 1), let gap = a.opts["gap"].flatMap(Double.init) { try await Task.sleep(for: .seconds(gap)) }
        }
    }
}
