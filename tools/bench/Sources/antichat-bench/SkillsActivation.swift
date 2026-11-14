// `antichat-bench skills-activation` (M7.T13 step 7; AT-263, R-263 AC1): does the real tier model use the right skill?
// The 20 skills of fixtures/skills/activation-20 are installed (all on) into a fresh store; each of the 100 prompts runs
// in a fresh chat through the app's own path — TurnController → SkillTools.plan (SkillSelector over the helper's
// embedding model, top M(tier) as `<available_skills>`, the pre-load on pre-load tiers) → the real chat model over XPC
// with `load_skill` offered. A skill counts as activated when its body entered the turn: `load_skill` succeeded or the
// selector pre-loaded it ("Using skill" lines). Correct = a gold row whose activated set is exactly {gold}; false = a
// no-skill row with any activation, or a gold row with a wrong skill activated. Bars: correct ≥ 0.75 (T1), ≥ 0.65 (T0);
// false ≤ 0.10 (over all 100 rows). The T2 leg moved to M11 (D-026).
//
//   antichat-bench skills-activation --skills fixtures/skills/activation-20 --fixture fixtures/prompts/skills-activation-100.jsonl
//                                    --tier T1 --out build/at/AT-263/<date>-T1.json [--model chat-9b-q4] [--context 16384]
//                                    [--theta 0.5] [--m 3] [--preload 0|1] [--limit N]
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Foundation

enum SkillsActivation {
    struct Row: Decodable { var id: String; var prompt: String; var gold: String? }

    static func run(_ a: BenchArgs) async throws {
        guard let skillsDir = a["skills"], let fixture = a["fixture"] else { throw BenchError("--skills and --fixture required") }
        let tierName = a["tier"] ?? "T1"
        guard let tier = DeviceTier(rawValue: tierName) else { throw BenchError("--tier T0|T1") }
        let key = a["model"] ?? (tier == .t0 ? "chat-2b" : "chat-9b-q4")
        let window = a.int("context", tier == .t0 ? 8192 : 16_384)
        let slot = DevSlots.slot(key)
        var tuning = SkillTools.Tuning()
        if let t = a["theta"].flatMap(Double.init) { tuning.theta = t }
        if let m = a["m"].flatMap(Int.init) { tuning.m = m }
        if let p = a["preload"] { tuning.preload = p == "1" }
        SkillTools.tuning = tuning

        let client = EngineClient(appBuild: "antichat-bench-skills")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        if let gb = DevSlots.tierB[tierName], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let embedSlot = DevSlots.slot("embed")
        let embedder: (any Embedder)? = FileManager.default.fileExists(atPath: embedSlot.path)
            ? HelperEmbedder(engine: client, embedSlot: { embedSlot }) : nil
        let selector = SkillSelector(embed: { texts, query in
            guard let embedder else { return nil }
            return try? await embedder.embed(texts, kind: query ? .query : .document)
        })
        let budgets = TierBudgets.shared.skills
        say("helper pid=\(ack.helperPID) model=\(key) tier=\(tierName) context=\(window) embedder=\(embedder != nil) "
            + "theta=\(tuning.theta ?? budgets?.theta[tierName] ?? -1) m=\(tuning.m ?? budgets?.candidatesM[tierName] ?? -1) load=\(SheetQA.loadAvg())")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("skills-activation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let db = try AppDatabase.onDisk(at: work.appendingPathComponent("antichat.sqlite"))
        let store = SkillStore(root: work.appendingPathComponent("Skills"), database: db)
        let root = URL(fileURLWithPath: skillsDir, isDirectory: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where !name.hasPrefix(".") {
            let s = try SkillImporter.install(try SkillImporter.inspect(root.appendingPathComponent(name)), into: store)
            try store.setEnabled(s.name, true)
        }
        say("installed \(store.list().count) skills")

        let rows = try String(contentsOf: URL(fileURLWithPath: fixture), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }.prefix(a.int("limit", 100))
        var out: [[String: Any]] = []
        var correct = 0, gold = 0, falseNone = 0, falseWrong = 0, none = 0, preloads = 0, loads = 0
        for (i, r) in rows.enumerated() {
            var runtime = ToolRuntime(registry: ToolRegistry([ScriptedTools.getTime()]), policy: .forTier(tier), selection: .standard,
                                      tier: { tier })
            runtime.skills = store
            runtime.skillSelector = selector
            runtime.skillScripts = SkillScriptPolicy(fileToolsInstalled: { false }, runCodeEnabled: { false })
            let chat = try ChatRepository(db).create().id
            let c = TurnController(chatID: chat, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 384), seed: 7),
                                   contextPolicy: ContextPolicy(windowOverride: window), tools: runtime) { slot }
            let aid = StorageID.make()
            let t0 = ContinuousClock.now
            let done = Task { () -> (TurnResult?, [String]) in
                var used: [String] = []
                for await u in c.updates where u.assistantID == aid {
                    if case .activity(let act) = u.kind, act.kind == .skill, !used.contains(act.tool) { used.append(act.tool) }
                    if case .finished(let res) = u.kind { return (res, used) }
                }
                return (nil, used)
            }
            await c.start(.send(userID: StorageID.make(), text: r.prompt, parentID: nil), assistantID: aid)
            let (res, used) = await done.value
            let plan = await c.lastSkillPlan
            let pre = plan?.preloaded.map(\.name) ?? []
            preloads += pre.count
            loads += used.filter { !pre.contains($0) }.count
            let activated = Set(used)
            var ok = false
            if let g = r.gold {
                gold += 1
                ok = activated == [g]
                if ok { correct += 1 }
                if !activated.subtracting([g]).isEmpty { falseWrong += 1 }
            } else {
                none += 1
                if !activated.isEmpty { falseNone += 1 }
                ok = activated.isEmpty
            }
            let listed = plan?.manifest.map { ["name": $0.name, "score": $0.score] as [String: Any] } ?? []
            out.append(["id": r.id, "prompt": r.prompt, "gold": r.gold ?? NSNull(), "activated": Array(activated).sorted(), "preloaded": pre,
                        "manifest": listed, "ok": ok, "status": res.map { "\($0.status)" } ?? "none",
                        "reply": String((res?.text ?? "").replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression).prefix(240)),
                        "secs": Stats.secs(ContinuousClock.now - t0)])
            say("\(i + 1)/\(rows.count) \(ok ? "ok  " : "MISS") gold=\(r.gold ?? "-") activated=\(activated.sorted()) pre=\(pre) top=\(listed.first?["name"] ?? "-")")
        }
        let correctRate = gold == 0 ? 0 : Double(correct) / Double(gold)
        let falseRate = Double(falseNone + falseWrong) / Double(max(rows.count, 1))
        let bar = tier == .t0 ? 0.65 : 0.75
        let pass = correctRate >= bar && falseRate <= 0.10
        let result: [String: Any] = [
            "cmd": "skills-activation", "at": "AT-263", "tier": tierName, "model": key, "context": window, "embedder": embedder != nil,
            "theta": tuning.theta ?? budgets?.theta[tierName] ?? NSNull(), "m": tuning.m ?? budgets?.candidatesM[tierName] ?? NSNull(),
            "preload": tuning.preload ?? budgets?.preload?[tierName] ?? (tier == .t0),
            "rows": rows.count, "gold_rows": gold, "none_rows": none, "correct": correct, "correct_rate": correctRate,
            "false_on_none": falseNone, "false_wrong_skill": falseWrong, "false_rate": falseRate, "bar_correct": bar, "bar_false": 0.10,
            "preloads": preloads, "load_skill_calls": loads, "pass": pass,
            "date": ISO8601DateFormatter().string(from: Date()), "load": SheetQA.loadAvg(), "items": out,
        ]
        let path = a["out"] ?? "build/at/AT-263/skills-activation-\(tierName).json"
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: u)
        say(String(format: "AT AT-263 %@ %@ correct=%d/%d (%.3f, bar %.2f) false=%d+%d/%d (%.3f, bar 0.10) preloads=%d loads=%d → %@",
                   tierName, pass ? "PASS" : "FAIL", correct, gold, correctRate, bar, falseNone, falseWrong, rows.count, falseRate, preloads, loads, path))
    }
}
