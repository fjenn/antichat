// `antichat-bench soak` (M2.T13 step 5, R-206 AC7 early check; the 8-h NFR-S3 soak is M9): a mini-soak through the
// real helper at a tier cap. Loop until `--minutes`: Normal chat turns (a new chat every 3 turns), a scripted media
// job with a real footprint every 3rd round (ScriptedImageEngine: MTLBuffers of the catalog image footprint, the
// chat model steps aside on T0–T2), a new Evil chat every 4th round (`--evil <dir>`: llama-server GGUF, crosses
// engines). Semantic searches join with M2.T16. A 1 Hz sampler records phys_footprint(helper + its children), i.e.
// what NFR-R1 bounds (unified memory: Metal allocations are in the footprint).
//
//   antichat-bench soak --cap T1 --minutes 60 --chat chat-9b-q4 [--evil <gguf dir> | --evil-key <MLX key>] [--image-gb 6.3] --csv <out> --json <out>
// M9.T05: `--evil-key` (an MLX Evil model by dev key, e.g. evil-35b-q4 for the T3-48 soak; the GGUF dir form stays).
import AntiChatHarness
import Darwin
import Foundation

enum SoakBench {
    static func phys(_ pid: pid_t) -> UInt64 {
        guard pid > 0 else { return 0 }
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    static func children(_ pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    static func llamaSlot(_ dir: String) -> ModelSlot {
        let url = URL(fileURLWithPath: dir)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let bytes = files.filter { $0.hasSuffix(".gguf") }.reduce(UInt64(0)) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent($1).resolvingSymlinksInPath().path)[.size] as? UInt64) ?? 0)
        }
        return ModelSlot(engine: .llama, key: url.lastPathComponent, path: dir, footprintBytes: UInt64(Double(bytes) * 1.1),
                         vision: files.contains { $0.contains("mmproj") }, contextTokens: 8192)
    }

    static func run(_ a: BenchArgs) async throws {
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let budget = UInt64(gb * 1e9)
        let minutes = Double(a["minutes"] ?? "60") ?? 60
        let chat = DevSlots.slot(a["chat"] ?? "chat-9b-q4")
        let evil = a["evil"].map(llamaSlot) ?? a["evil-key"].map { DevSlots.slot($0) }
        let imageGB = Double(a["image-gb"] ?? "6.3") ?? 6.3
        let client = EngineClient(appBuild: "antichat-bench-soak")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let helper = ack.helperPID
        try await client.setPolicy(SetPolicy(budgetB: budget, lowTier: !cap.hasPrefix("T3") && !cap.hasPrefix("T4")))
        say("soak cap=\(cap) B=\(budget) minutes=\(minutes) helper=\(helper) chat=\(chat.key) evil=\(evil?.key ?? "-") image=\(imageGB) GB")

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var rows: [String] = ["t_s,helper_pid,footprint_bytes,helper_bytes,children"]
            var peak: UInt64 = 0
        }
        let box = Box()
        let start = ContinuousClock.now
        let sampler = Task.detached {
            while !Task.isCancelled {
                let kids = children(helper)
                let h = phys(helper)
                let total = kids.reduce(h) { $0 + phys($1) }
                let t = Stats.secs(ContinuousClock.now - start)
                box.lock.withLock {
                    box.peak = max(box.peak, total)
                    box.rows.append(String(format: "%.1f,%d,%llu,%llu,%d", t, helper, total, h, kids.count))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        var turns = 0, jobs = 0, evils = 0, errors: [String] = []
        var session = UUID()
        var round = 0
        let deadline = start + .seconds(minutes * 60)
        func ask(_ slot: ModelSlot, _ s: UUID, _ text: String) async {
            let req = ChatRequest(sessionID: s, modelSlot: slot, messages: [ChatMessage(role: .user, content: text)],
                                  sampling: Sampling(maxTokens: 48))
            for await b in client.chatBatches(req) {
                for e in b.events { if case .error(let x) = e { errors.append("\(slot.key): \(x.code)") } }
            }
        }
        while ContinuousClock.now < deadline {
            round += 1
            if round % 3 == 1 { session = UUID() }
            await ask(chat, session, "Round \(round): name one fruit and one colour.")
            turns += 1
            if round % 3 == 0 {
                let set = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:6:100", llm: "", vae: "",
                                        footprintBytes: UInt64(imageGB * 1e9))
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("soak-\(round).png")
                for await b in client.image(ImageRequest(model: set, prompt: "x", width: 1, height: 1, steps: 6, seed: 1, preview: "none", outputPath: out.path)) {
                    for e in b.events { if case .error(let x) = e { errors.append("image: \(x.code)") } }
                }
                try? FileManager.default.removeItem(at: out)
                jobs += 1
            }
            if let evil, round % 4 == 0 {
                await ask(evil, UUID(), "Round \(round): say one short sentence.")
                evils += 1
            }
        }
        sampler.cancel()
        let probe = try? await client.probe()
        let alive = kill(helper, 0) == 0
        let (csv, pk) = box.lock.withLock { (box.rows.joined(separator: "\n") + "\n", box.peak) }
        if let path = a["csv"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let out: [String: Any] = [
            "cap": cap, "budget_b": budget, "minutes": minutes, "helper_pid_start": Int(helper), "helper_pid_end": Int(probe?.pid ?? -1),
            "helper_alive": alive, "peak_bytes": pk, "peak_le_b": budget == 0 || pk <= budget, "turns": turns, "image_jobs": jobs,
            "evil_chats": evils, "errors": errors, "chat": chat.key, "evil": evil?.key ?? "", "image_gb": imageGB,
            "semantic_search": "pending (M2.T16)", "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        if let path = a["json"] { try data.write(to: URL(fileURLWithPath: path)) } else { FileHandle.standardOutput.write(data) }
        say("soak done: turns=\(turns) jobs=\(jobs) evil=\(evils) errors=\(errors.count) peak=\(pk) B=\(budget) helper alive=\(alive)")
    }
}
