// `antichat-bench tool-select` (M7.T14; AT-266 c1/c2, R-266 AC1/AC2): the load-when-needed selector over 40 enabled
// tools and tool-select-200 at one tier. Per prompt: the pre-router (bundled prototypes, the helper's embed model) gives
// the intent tools, ToolIndex ranks the 40 tools (BM25 + the same embed model, RRF), ToolSelector picks the step's
// set. c1: the set never exceeds the tier's `tools.max_per_step` (tier-budgets.json). c2: the gold tool (or one of
// its `also` alternatives) is in the set; for a "none" prompt the selector's own pick is empty.
// Bars (R-266 AC2, hypotheses): ≥ 0.85 at T2, ≥ 0.70 at T0.
//   antichat-bench tool-select --tools fixtures/tools/forty-tools.json --fixture fixtures/prompts/tool-select-200.jsonl
//                              --tier T2 [--min-cosine x] [--sweep a,b,…] [--no-embed] --out build/at/AT-266/<date>-T2.json
//   antichat-bench tool-select --dump-builtins <file>   (the app's built-in tool definitions, for make-tool-select.py)
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation

enum ToolSelect {
    struct Tool: Decodable { var name: String; var description: String; var parameters: AnyJSON }
    struct Row: Decodable { var id: String; var lang: String; var prompt: String; var gold: String; var also: [String] }

    /// Any JSON value, re-serialised as the schema text.
    struct AnyJSON: Decodable {
        var text: String
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(JSONValueBox.self)
            text = String(decoding: try JSONSerialization.data(withJSONObject: raw.value, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    static func run(_ a: BenchArgs) async throws {
        if let out = a["dump-builtins"] { return try dumpBuiltins(out) }
        guard let toolsPath = a["tools"], let fixture = a["fixture"] else {
            throw BenchError("--tools <forty-tools.json> and --fixture <tool-select-200.jsonl> are required")
        }
        guard let tier = DeviceTier(rawValue: a["tier"] ?? "T2") else { throw BenchError("--tier T0…T4") }
        let tools = try JSONDecoder().decode([Tool].self, from: Data(contentsOf: URL(fileURLWithPath: toolsPath)))
            .map { ToolSchema(name: $0.name, description: $0.description, parametersJSON: $0.parameters.text) }
        // M7 bars (A-M7-T14a b): the Composio tools as the app describes them (MCPToolProxy.composioDescription; the
        // fixture holds Composio's own tools/list text).
        let indexTools: [ToolSchema] = tools.map { t in
            guard t.name.hasPrefix("composio_composio_") else { return t }
            let tool = "COMPOSIO_" + t.name.dropFirst("composio_composio_".count).uppercased()
            return ToolSchema(name: t.name, description: MCPToolProxy.composioDescription(t.description, tool: tool), parametersJSON: t.parametersJSON)
        }
        let rows = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let minCos = a["min-cosine"].flatMap(Float.init) ?? ToolSelector.minEmbedCosine
        var embedding: (any RouteEmbedding)?
        var router: PreRouter?
        var engineClient: EngineClient?
        defer { engineClient?.disconnect() }  // an undisconnected XPC session traps at deinit (bench exit 133)
        if a["no-embed"] == nil {
            let client = EngineClient(appBuild: "antichat-bench-tool-select")
            engineClient = client
            _ = try await client.ensureConnected()
            let slot = DevSlots.slot("embed")
            let emb = DeferredRouteEmbedding()
            emb.set(HelperEmbedder(engine: client, embedSlot: { slot }))
            embedding = emb
            router = PreRouter.bundled(embedding: emb)
            router?.sendBudget = nil  // the bench measures selection, not the 10 ms send budget
            if let s = router?.scorer { await s.prepare() }
        }
        let index = ToolIndex(embedding: embedding)
        if embedding != nil, !(await index.prepare(indexTools)) { throw BenchError("embedding the 40 tools failed") }
        let budget = ToolSelector.Budget.forTier(tier)
        // Diagnostic only (docs/prd/M7-owner-steps.md §1): --cap N replaces the per-step cap (R-235 AC2 vs B4.6).
        let capOverride = a["cap"].flatMap(Int.init)
        let cap = capOverride ?? ToolSelector.cap(tier, budget: budget)
        // Per prompt once: the router's intent tools and the message vector (the sweep reuses them).
        var routedBy: [String: [String]] = [:], vectorBy: [String: [Float]] = [:]
        for r in rows {
            let d = await router?.decide(userText: r.prompt, hasImage: false, chips: [], tools: tools, tier: tier)
            routedBy[r.id] = d?.routedTools ?? []
            if let v = await router?.scorer?.cachedVector(r.prompt) { vectorBy[r.id] = v }
        }
        var sweep: [[String: Any]] = []
        for c in (a["sweep"] ?? "").split(separator: ",").compactMap({ Float($0) }) {
            var ok = 0
            for r in rows {
                let hits = await index.search(query: r.prompt, queryVector: vectorBy[r.id], among: indexTools, minEmbedCosine: c)
                let sel = ToolSelector.select(eligible: indexTools, routed: routedBy[r.id] ?? [], hits: hits, tier: tier, budget: budget, capOverride: capOverride)
                let names = sel.tools.map(\.name)
                if r.gold == "none" ? sel.top == nil : ([r.gold] + r.also).contains(where: names.contains) { ok += 1 }
            }
            let acc = Double(ok) / Double(max(1, rows.count))
            sweep.append(["min_cosine": Double(c), "accuracy": acc])
            say("  sweep cos ≥ \(c): \(String(format: "%.3f", acc))")
        }
        var right = 0, overCap = 0, goldRight = 0, goldN = 0, noneRight = 0, noneN = 0
        var out: [[String: Any]] = [], byLang: [String: [Int]] = [:]
        let started = ContinuousClock.now
        for r in rows {
            let routed = routedBy[r.id] ?? []
            let hits = await index.search(query: r.prompt, queryVector: vectorBy[r.id], among: indexTools, minEmbedCosine: minCos)
            let sel = ToolSelector.select(eligible: indexTools, routed: routed, hits: hits, tier: tier, budget: budget, capOverride: capOverride)
            let names = sel.tools.map(\.name)
            if names.count > budget.maxPerStep { overCap += 1 }
            let ok: Bool
            if r.gold == "none" {
                noneN += 1
                ok = sel.top == nil
                if ok { noneRight += 1 }
            } else {
                goldN += 1
                ok = ([r.gold] + r.also).contains { names.contains($0) }
                if ok { goldRight += 1 }
            }
            if ok { right += 1 }
            byLang[r.lang, default: [0, 0]][0] += ok ? 1 : 0
            byLang[r.lang, default: [0, 0]][1] += 1
            out.append(["id": r.id, "lang": r.lang, "prompt": r.prompt, "gold": r.gold, "also": r.also, "ok": ok,
                        "offered": names, "top": sel.top ?? "", "routed": routed,
                        "hits": hits.prefix(5).map { ["name": $0.name, "fused": Double($0.fusedScore),
                                                       "cos": $0.embedScore.map(Double.init) ?? -1, "bm25": $0.bm25Rank ?? 0,
                                                       "relevant": $0.relevant] }])
        }
        let elapsed = ContinuousClock.now - started
        let accuracy = Double(right) / Double(max(1, rows.count))
        let bar = tier == .t0 ? 0.70 : tier == .t2 ? 0.85 : nil
        let pass = overCap == 0 && (bar.map { accuracy >= $0 } ?? true)
        let report: [String: Any] = [
            "cmd": "tool-select", "tier": tier.rawValue, "tools": tools.count, "rows": rows.count,
            "max_per_step": budget.maxPerStep, "cap_applied": cap, "schema_token_cap": budget.schemaTokenCap,
            "min_embed_cosine": Double(minCos), "embedding": embedding?.modelID ?? "none (lexical only)",
            "router": router != nil, "accuracy": accuracy, "right": right, "gold_right": goldRight, "gold_rows": goldN,
            "none_right": noneRight, "none_rows": noneN, "over_cap": overCap, "bar": bar ?? NSNull(), "pass": pass,
            "by_lang": byLang.mapValues { ["right": $0[0], "rows": $0[1]] },
            "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "date": ISO8601DateFormatter().string(from: Date()),
            "sweep": sweep, "misses": out.filter { ($0["ok"] as? Bool) == false }, "results": out,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let o = a["out"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: o).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: o))
            say("wrote \(o)")
        }
        say("tool-select \(tier.rawValue): accuracy \(String(format: "%.3f", accuracy)) (tools \(goldRight)/\(goldN), none \(noneRight)/\(noneN)) "
            + "over-cap \(overCap) cap \(cap)/\(budget.maxPerStep) cos ≥ \(minCos) \(pass ? "PASS" : "FAIL")")
    }

    /// The app's built-in tools as the registry defines them (+ the image tools' static schemas).
    static func dumpBuiltins(_ path: String) throws {
        let db = try AppDatabase.inMemory()
        let runtime = ToolRuntime.app(database: db)
        var schemas = runtime.registry.all.map(\.schema)
        schemas.append(ToolSchema(name: CreateImageTool.name, description: CreateImageTool.description, parametersJSON: CreateImageTool.parametersJSON))
        schemas.append(ToolSchema(name: EditImageTool.name, description: EditImageTool.description, parametersJSON: EditImageTool.parametersJSON))
        let list: [[String: Any]] = schemas.map {
            ["name": $0.name, "description": $0.description,
             "parameters": (try? JSONSerialization.jsonObject(with: Data($0.parametersJSON.utf8))) ?? [:]]
        }
        try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        say("wrote \(schemas.count) built-in tools to \(path)")
    }
}

/// A decoded JSON value as Foundation objects.
struct JSONValueBox: Decodable {
    var value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([JSONValueBox].self) { value = a.map(\.value) }
        else { value = try c.decode([String: JSONValueBox].self).mapValues(\.value) }
    }
}
