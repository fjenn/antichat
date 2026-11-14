// `antichat-bench sheet-chart` (M6.T12 step 7; AT-274 check 3, R-274 AC3): for each sheet-to-chart-20 prompt a real turn
// (AttachmentIntake → TurnController with query_data + create_chart → the real chat model over XPC). Scored on the
// chart's snapshot (the exact rows the host injected into spec.data.values): its [label, value] pairs must equal
// `aggregates_gold` (computed from the file by tools/fixtures/make-sheet-chart.py, independent of DuckDB): integers
// exactly, floats ≤ 1e-9 relative. The label column is the snapshot's first text-like column, the value column the
// first numeric one that matches; `summary.json.match_rate` = matched / prompts.
//
//   antichat-bench sheet-chart --fixture fixtures/prompts/sheet-to-chart-20.jsonl --tier T1 --out <dir> [--model chat-9b-q4]
//                              [--limit N] [--only sc-01,sc-03] [--max-tokens 1536]
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation

enum SheetChart {
    struct Item: Decodable {
        var id: String; var files: [String]; var prompt: String; var mark: String; var aggregates_gold: [[Gold]]
        enum Gold: Decodable {
            case s(String), n(Double)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let n = try? c.decode(Double.self) { self = .n(n) } else { self = .s(try c.decode(String.self)) }
            }
            var text: String { switch self { case .s(let s): s; case .n(let n): String(n) } }
            var number: Double? { if case .n(let n) = self { n } else { nil } }
        }
    }

    static func close(_ a: Double, _ b: Double) -> Bool { a == b || abs(a - b) <= 1e-9 * max(abs(a), abs(b)) }

    /// Label normalisation: dates "2025-03-01" / "2025-03-01 00:00:00" → "2025-03" when the gold label is a month.
    static func norm(_ label: String, like gold: String) -> String {
        if gold.count == 7, gold.dropFirst(4).first == "-", label.count >= 7 { return String(label.prefix(7)) }
        return label
    }

    /// Does any (label column, value column) pair of the snapshot equal the gold pairs?
    static func matches(_ snap: ChartSnapshot, _ gold: [[Item.Gold]]) -> Bool {
        let want = gold.compactMap { g -> (String, Double)? in
            guard g.count == 2, let v = g[1].number else { return nil }
            return (g[0].text, v)
        }
        guard !want.isEmpty, snap.rows.count == want.count else { return false }
        for li in snap.columns.indices {
            for vi in snap.columns.indices where vi != li {
                var got: [String: Double] = [:]
                var ok = true
                for r in snap.rows {
                    guard li < r.count, vi < r.count, let l = r[li], let v = r[vi].flatMap(Double.init) else { ok = false; break }
                    got[norm(l, like: want[0].0)] = v
                }
                if ok, got.count == want.count, want.allSatisfy({ w in got[w.0].map { close($0, w.1) } ?? false }) { return true }
            }
        }
        return false
    }

    @MainActor
    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture required") }
        let tierName = a["tier"] ?? "T1"
        let key = a["model"] ?? "chat-9b-q4"
        let office = URL(fileURLWithPath: fixture).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/office")
        let items = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
            .filter { it in a["only"].map { $0.split(separator: ",").map(String.init).contains(it.id) } ?? true }
            .prefix(a.int("limit", 1000))
        let cap = tierName == "T2" ? "T2-24" : tierName
        let tier: DeviceTier = DeviceTier(rawValue: tierName) ?? .t1
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-sheetchart")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let outDir = URL(fileURLWithPath: a["out"] ?? "build/at/AT-274/sheet-chart")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        say("helper pid=\(ack.helperPID) model=\(key) tier=\(tierName) items=\(items.count) load=\(SheetQA.loadAvg())")
        var rows: [[String: Any]] = []
        var matched = 0
        let start = ContinuousClock.now
        for (i, it) in items.enumerated() {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("sheetchart-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let db = try AppDatabase.inMemory()
            let intake = AttachmentIntake(database: db, mediaRoot: work.appendingPathComponent("Media"), incognito: false)
            var ids: [String] = []
            for f in it.files {
                let item = await intake.ingest(AttachmentIntake.admit([office.appendingPathComponent(f)]).items[0])
                guard let id = item.attachmentID else { throw BenchError("intake failed for \(f): \(item.state)") }
                ids.append(id)
            }
            let store = ArtifactStore(database: db, mediaRoot: work.appendingPathComponent("Out"), incognito: false)
            let registry = ToolRegistry([SheetTools.queryData(), FileOutTools.createChart(store: store)])
            let rt = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(tier),
                                 selection: .standard, tier: { tier })
            let chat = try ChatRepository(db).create(title: it.id).id
            defer { SheetSessions.shared.close(chatID: chat); DataRefStore.shared.drop(chatID: chat) }
            let c = TurnController(chatID: chat, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 1536), seed: 7),
                                   tools: rt) { slot }
            let aid = StorageID.make()
            let t = ContinuousClock.now
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: it.prompt, parentID: nil, attachmentIDs: ids), assistantID: aid)
            let res = await done.value
            let acts = ToolActivity.activities(in: (try? MessageRepository(db).parts(of: aid)) ?? [])
            let charts = acts.filter { $0.tool == CreateChartTool.name && $0.state == .done }
            let snap = charts.last?.result.flatMap(FileOutResult.parse).flatMap { ChartSnapshot.load(png: URL(fileURLWithPath: $0.path)) }
            let hit = snap.map { matches($0, it.aggregates_gold) } ?? false
            if hit { matched += 1 }
            if let snap, let r = charts.last?.result.flatMap(FileOutResult.parse) {
                let png = outDir.appendingPathComponent("\(it.id).png")
                try? FileManager.default.removeItem(at: png)  // a rerun replaces the earlier run's chart
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: r.path), to: png)
                try? Data(snap.spec.utf8).write(to: outDir.appendingPathComponent("\(it.id).vl.json"))
            }
            let reply: String = String((res?.text ?? "").prefix(400))
            let calls: [[String: Any]] = acts.map { c in
                ["tool": c.tool, "state": "\(c.state)", "args": String(c.argumentsJSON.prefix(1200)),
                 "result": String((c.result ?? "").prefix(400))]
            }
            // M6.T21: one entry per engine step (auto / required / function:<name>), to see a forced step in a miss.
            let steps = await c.requests.map { r -> String in
                switch r.toolChoice { case .function(let n)?: "function:\(n)"; case let ch?: "\(ch)"; case nil: "default" }
            }
            var row: [String: Any] = ["reply": reply, "calls": calls, "steps": steps, "reasoning_tail": String((res?.reasoning ?? "").suffix(600)),
                                      "error": res?.errorCode ?? ""]
            row.merge(["id": it.id, "prompt": it.prompt, "match": hit, "chart_calls": acts.filter { $0.tool == CreateChartTool.name }.count,
                         "queries": acts.filter { $0.tool == QueryDataTool.name }.map(\.argumentsJSON),
                         "injected_columns": snap?.columns ?? [], "injected_rows": snap?.rows.count ?? 0,
                         "failures": acts.filter { $0.state == .failed }.compactMap(\.result),
                         "status": res.map { "\($0.status)" } ?? "none", "secs": Stats.secs(ContinuousClock.now - t)]) { a, _ in a }
            rows.append(row)
            say("\(i + 1)/\(items.count) \(hit ? "ok  " : "MISS") \(it.id) charts=\(charts.count) rows=\(snap?.rows.count ?? 0) cols=\(snap?.columns ?? [])")
        }
        let summary: [String: Any] = [
            "cmd": "sheet-chart", "tier": tierName, "model": key, "items": items.count, "matched": matched,
            "match_rate": Double(matched) / Double(max(1, items.count)), "seconds": Stats.secs(ContinuousClock.now - start),
            "date": ISO8601DateFormatter().string(from: Date()), "load": SheetQA.loadAvg(), "rows": rows,
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("summary.json"))
        say("match_rate \(Double(matched) / Double(max(1, items.count))) (\(matched)/\(items.count)) → \(outDir.path)")
    }
}
