// M1.T25a AT-234 unit leg (R-234 AC1): `make test-unit FILTER=ProvenanceRecorderTests` — after 10 turns (incl. a
// regenerate and an interrupted one) every assistant row has non-null model_id, engine, model_sha, mode, sampling
// and tok_per_s (interrupted: the partial's rate), plus ttft_ms and prompt_hash; the export carries it. The model
// fingerprint (ModelManifestSHA) and prompt hash rules are checked directly. The Model info popover (AC2) is T25b.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ProvenanceRecorderTests") struct ProvenanceRecorderTests {
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    @Test func tenTurnsIncludingRegenerateAndInterruptedAllCarryProvenance() async throws {
        // Explicit steps, not a race with the wall clock. Each turn is 12 deltas of ten words (2 ms apart, so the decode
        // rate has a time base) — it was 120 single-word deltas at 2 ms, 1,200 sleeps and actor hops over the ten
        // turns, and under load (~60) one turn's hops alone outlasted the 10 s wait (TimeoutError). The interrupted
        // turn (turn 6, segment 5: five assistant replies in its prompt) holds in a `wait` after its first 12 deltas
        // until Stop cancels it, so Stop always lands mid-reply instead of racing the reply's end.
        let reply = #"{"t":"textDelta","v":" one two three four five six seven eight nine ten","delayMs":2,"repeat":12}"#
        let held = reply + "\n" + #"{"t":"wait","ms":600000}"# + "\n" + reply
        let script = ([String](repeating: reply, count: 5) + [held, reply]).joined(separator: "\n{\"t\":\"turn\"}\n")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prov-\(UUID().uuidString).jsonl")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let db = try AppDatabase.inMemory()
        let chatID = StorageID.make()
        let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
        let sampling = Sampling(temperature: 0.7, topP: 0.9, topK: 20, maxTokens: 512, seed: 99)
        // A pinned clock: the per-minute time line is part of the hashed prompt, so a minute boundary between turn 8
        // and its regenerate would otherwise change the hash (flaked under load in the full suite).
        let clock = VolatileContext(now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let controller = TurnController(chatID: chatID, database: db, engine: engine, mode: .normal, sampling: sampling,
                                        volatileContext: { clock }) {
            .scripted(file.path, key: "scripted-prov")
        }
        let log = UpdateLog(controller)
        var assistants: [String] = []
        var parent: String?
        for i in 0..<8 {
            let u = StorageID.make(), a = StorageID.make()
            await controller.start(.send(userID: u, text: "question \(i)", parentID: parent), assistantID: a)
            if i == 5 {  // interrupted turn
                try await log.wait { $0.text(a).count > 60 }
                await controller.stop()
            }
            let r = try await log.waitFinished(a)
            #expect(r.status == (i == 5 ? .interrupted : .done), "turn \(i)")
            assistants.append(a)
            parent = a
        }
        // Turn 9: regenerate the last answer; turn 10: a follow-up on the new version.
        let regen = StorageID.make()
        await controller.start(.retry(assistantID: assistants.last!), assistantID: regen)
        #expect(try await log.waitFinished(regen).status == .done)
        assistants.append(regen)
        let u10 = StorageID.make(), a10 = StorageID.make()
        await controller.start(.send(userID: u10, text: "last one", parentID: regen), assistantID: a10)
        _ = try await log.waitFinished(a10)
        assistants.append(a10)
        #expect(assistants.count == 10)

        let scriptSHA = Self.sha(try Data(contentsOf: file))
        var hashes: [String] = []
        for (i, id) in assistants.enumerated() {
            let m = try #require(try MessageRepository(db).message(id), "row \(i)")
            #expect(m.modelID == "scripted-prov", "row \(i)")
            #expect(m.engine == "scripted", "row \(i)")
            let p = try #require(m.provenance, "row \(i) provenance")
            #expect(p.modelSHA == scriptSHA, "row \(i)")
            #expect(p.mode == .normal)
            #expect(p.sampling?["temperature"] == 0.7 && p.sampling?["top_k"] == 20 && p.sampling?["seed"] == 99 && p.sampling?["max_tokens"] == 512)
            let tps = try #require(p.tokPerS, "row \(i) tok/s")
            #expect(tps > 0, "row \(i) tok/s \(tps)")
            #expect(p.ttftMs != nil)
            #expect(p.promptHash?.count == 64)
            hashes.append(p.promptHash ?? "")
            if i == 5 { #expect(m.status == .interrupted) }
        }
        // Regenerate re-sends the same prompt as the version it replaces; every other turn's prompt differs.
        #expect(hashes[8] == hashes[7])
        #expect(Set(hashes).count == 9)
        // The export (TreeExport, antichat.tree.v1) includes provenance.
        let doc = try JSONSerialization.jsonObject(with: TreeExport.exportJSON(chatID, from: db)) as? [String: Any]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: doc ?? [:]), as: UTF8.self)
        #expect(text.contains(scriptSHA))
        #expect(text.contains("prompt_hash"))
    }

    @Test func interruptedWithoutUsageEstimatesThePartialRate() {
        let slot = ModelSlot.scripted("/nonexistent", key: "x")
        let req = ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "hi")])
        let t0 = ContinuousClock.now
        var r = ProvenanceRecorder(request: req, mode: .evil, modelSHA: "abc", sentAt: t0)
        r.observe(.textDelta(String(repeating: "x", count: 40)), at: t0 + .milliseconds(100))
        r.observe(.textDelta(String(repeating: "y", count: 40)), at: t0 + .milliseconds(1100))
        r.observe(.done(.cancelled), at: t0 + .milliseconds(1150))
        let p = r.provenance()
        #expect(p.tokPerSSource == "app-estimate")
        #expect(abs((p.tokPerS ?? 0) - 20) < 0.5, "80 chars / 4 over 1 s")
        #expect(abs((p.ttftMs ?? 0) - 100) < 1)
        #expect(p.mode == .evil && p.modelSHA == "abc")
        // With an engine usage (the helper also counts one for a cancelled turn) that rate wins.
        r.observe(.usage(Usage(promptTokens: 3, completionTokens: 30, ttftMs: 42, generateTime: 1.5)))
        #expect(r.provenance().tokPerS == 20 && r.provenance().tokPerSSource == "engine" && r.provenance().ttftMs == 42)
    }

    @Test func promptHashIsCanonical() {
        let slot = ModelSlot.scripted("/s")
        let a = ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "hi")])
        var b = a
        b.requestID = UUID()
        b.sampling = Sampling(temperature: 0.1)
        #expect(ProvenanceRecorder.promptHash(a) == ProvenanceRecorder.promptHash(b), "ids and sampling are not prompt")
        let c = ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "hi!")])
        #expect(ProvenanceRecorder.promptHash(a) != ProvenanceRecorder.promptHash(c))
        var d = a
        d.tools = [ToolSchema(name: "get_time", description: "t")]
        #expect(ProvenanceRecorder.promptHash(a) != ProvenanceRecorder.promptHash(d))
    }

    @Test func modelSHAComesFromTheManifest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prov-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m1 = #"{"repo":"r/m","commit":"c1","files":[{"path":"b","oid":"2"},{"path":"a","oid":"1","lfs":{"oid":"L"}}]}"#
        try m1.write(to: dir.appendingPathComponent(".hf-fetch.json"), atomically: true, encoding: .utf8)
        let s1 = ModelManifestSHA.compute(ModelSlot(engine: .mlx, key: "m", path: dir.path))
        // Same content, other key order / file order → same fingerprint; another commit → another.
        let m2 = #"{"files":[{"oid":"1","path":"a","lfs":{"oid":"L"}},{"oid":"2","path":"b"}],"commit":"c1","repo":"r/m"}"#
        try m2.write(to: dir.appendingPathComponent(".hf-fetch.json"), atomically: true, encoding: .utf8)
        #expect(ModelManifestSHA.compute(ModelSlot(engine: .mlx, key: "m", path: dir.path)) == s1)
        try m1.replacingOccurrences(of: "c1", with: "c2").write(to: dir.appendingPathComponent(".hf-fetch.json"), atomically: true, encoding: .utf8)
        #expect(ModelManifestSHA.compute(ModelSlot(engine: .mlx, key: "m", path: dir.path)) != s1)
        // A GGUF file uses its directory's manifest.
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("w.gguf"))
        #expect(ModelManifestSHA.compute(ModelSlot(engine: .llama, key: "g", path: dir.appendingPathComponent("w.gguf").path)) != nil)
        #expect(ModelManifestSHA.compute(ModelSlot(engine: .mlx, key: "none", path: "/nonexistent")) == nil)
        // The real dev store, when present: a 64-hex fingerprint.
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models/chat-0.8b")
        if FileManager.default.fileExists(atPath: real.appendingPathComponent(".hf-fetch.json").path) {
            #expect(ModelManifestSHA.compute(ModelSlot(engine: .mlx, key: "chat-0.8b", path: real.path))?.count == 64)
        }
    }
}
